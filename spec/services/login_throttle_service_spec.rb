# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LoginThrottleService do
  # Minimal stand-in for the Redis commands the service uses. TTLs are stored as
  # given rather than counted down: the specs only assert what the service asked
  # Redis to remember.
  class FakeRedis
    def initialize
      @values = {}
      @ttls = {}
      @sets = {}
    end

    def incr(key)
      @values[key] = @values.fetch(key, 0) + 1
    end

    def expire(key, seconds)
      @ttls[key] = seconds
    end

    def set(key, value, ex: nil)
      @values[key] = value
      @ttls[key] = ex
    end

    def ttl(key)
      @ttls.key?(key) ? @ttls[key] : -2
    end

    def del(*keys)
      keys.each do |key|
        @values.delete(key)
        @ttls.delete(key)
        @sets.delete(key)
      end
    end

    def sadd(key, member)
      @sets[key] ||= []
      @sets[key] |= [member]
    end

    def scard(key)
      @sets.fetch(key, []).size
    end

    def value(key)
      @values[key]
    end

    def exists?(key)
      @values.key?(key)
    end

    def all_keys
      (@values.keys + @sets.keys).uniq
    end
  end

  let(:redis) { FakeRedis.new }
  let(:username) { "throttle_spec_#{SecureRandom.hex(4)}" }

  before do
    allow(described_class).to receive(:with_redis) { |&block| block.call(redis) }
  end

  def fail_times(count, user: nil)
    count.times { described_class.record_failure(username, user:) }
  end

  describe 'progressive back-off' do
    it 'lets the first three failures through without a delay' do
      fail_times(3)

      expect(described_class.retry_after(username)).to be_nil
      expect { described_class.check!(username) }.not_to raise_error
    end

    it 'blocks the fourth attempt for five seconds' do
      fail_times(4)

      expect { described_class.check!(username) }
        .to raise_error(TooManyRequestsError) { |error| expect(error.retry_after).to eq(5) }
    end

    it 'lengthens the delay on each further failure' do
      { 5 => 15, 6 => 30, 7 => 60, 8 => 60, 9 => 60 }.each do |failures, expected|
        described_class.record_success(username)
        fail_times(failures)

        expect(described_class.retry_after(username)).to eq(expected)
      end
    end
  end

  describe 'soft lock' do
    it 'locks for fifteen minutes on the tenth consecutive failure' do
      fail_times(described_class::LOCK_THRESHOLD)

      expect(described_class.retry_after(username)).to eq(15.minutes.to_i)
      expect(described_class).to be_locked(username)
    end

    it 'reports the lock through the same error as a back-off' do
      fail_times(described_class::LOCK_THRESHOLD)

      expect { described_class.check!(username) }
        .to raise_error(TooManyRequestsError, described_class::MESSAGE)
    end

    it 'is cleared by an administrative unlock' do
      fail_times(described_class::LOCK_THRESHOLD)

      described_class.unlock!(username)

      expect(described_class).not_to be_locked(username)
    end
  end

  describe 'counter reset' do
    it 'forgets previous failures after a successful login' do
      fail_times(4)
      described_class.record_success(username)

      fail_times(1)

      expect(described_class.retry_after(username)).to be_nil
    end
  end

  describe 'key normalisation' do
    it 'treats usernames case-insensitively' do
      4.times { described_class.record_failure(username.upcase) }

      expect(described_class.retry_after(username.downcase)).to eq(5)
    end
  end

  describe 'unknown usernames' do
    it 'throttles them exactly like real accounts, so the limit reveals nothing' do
      4.times { described_class.record_failure('no-such-user-ever') }

      expect(described_class.retry_after('no-such-user-ever')).to eq(5)
    end

    it 'audits the attempted username with no user attached' do
      expect { described_class.record_failure('no-such-user-ever') }
        .to change(Audited::Audit.where(action: 'failed_login'), :count).by(1)

      audit = Audited::Audit.where(action: 'failed_login').order(:id).last
      expect(audit.username).to eq('no-such-user-ever')
      expect(audit.auditable_id).to be_nil
    end
  end

  describe 'audit trail' do
    it 'records a lock separately from an ordinary failure' do
      expect { fail_times(described_class::LOCK_THRESHOLD) }
        .to change(Audited::Audit.where(action: 'account_locked'), :count).by(1)
    end
  end

  describe 'counter bookkeeping' do
    it 'gives the failure counter a sliding fifteen-minute expiry' do
      fail_times(1)

      expect(redis.ttl("#{described_class::KEY_PREFIX}fails:#{username.downcase}"))
        .to eq(described_class::COUNTER_TTL.to_i)
    end

    it 'expires the counter together with a lock, so waiting one out grants free attempts again' do
      fail_times(described_class::LOCK_THRESHOLD)

      counter_ttl = redis.ttl("#{described_class::KEY_PREFIX}fails:#{username.downcase}")
      expect(counter_ttl).to eq(described_class::LOCK_DURATION.to_i)
      expect(counter_ttl).to be <= redis.ttl("#{described_class::KEY_PREFIX}wait:#{username.downcase}")
    end

    it 'deletes both keys on success' do
      fail_times(4)

      described_class.record_success(username)

      expect(redis).not_to be_exists("#{described_class::KEY_PREFIX}fails:#{username.downcase}")
      expect(redis).not_to be_exists("#{described_class::KEY_PREFIX}wait:#{username.downcase}")
    end
  end

  describe 'blank and malformed usernames' do
    it 'does not raise or count anything for a blank username' do
      expect { described_class.record_failure('') }.not_to change(Audited::Audit, :count)
      expect { described_class.record_failure(nil) }.not_to change(Audited::Audit, :count)
      expect { described_class.check!('') }.not_to raise_error
      expect { described_class.check!(nil) }.not_to raise_error
      expect(described_class.retry_after('   ')).to be_nil
    end

    it 'shares a counter across surrounding whitespace, which the database ignores too' do
      4.times { described_class.record_failure("  #{username}  ") }

      expect(described_class.retry_after(username)).to eq(5)
    end
  end

  describe 'unlocking an account that was never locked' do
    it 'is a no-op rather than an error' do
      expect { described_class.unlock!('never-seen-this-user') }.not_to raise_error
    end
  end

  describe 'audit contents' do
    it 'records the failure count and remote address' do
      Audited.store[:current_remote_address] = '10.1.2.3'
      fail_times(2)

      audit = Audited::Audit.where(username:, action: 'failed_login').order(:id).last
      expect(audit.audited_changes['consecutive_failures']).to eq(2)
      expect(audit.remote_address).to eq('10.1.2.3')
    ensure
      Audited.store[:current_remote_address] = nil
    end

    it 'attaches the row to the user when the account exists' do
      user = User.first
      skip 'no users in the test database' unless user

      described_class.record_failure(username, user:)

      audit = Audited::Audit.where(username:, action: 'failed_login').order(:id).last
      expect(audit.auditable_id).to eq(user.user_id)
      expect(audit.auditable_type).to eq('User')
    end

    it 'never lets an audit failure turn a wrong password into a server error' do
      allow(Audited::Audit).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'audits table is gone')

      expect { described_class.record_failure(username) }.not_to raise_error
      # The throttle itself must still have counted the attempt.
      expect(described_class.retry_after(username)).to be_nil
      fail_times(3)
      expect(described_class.retry_after(username)).to eq(5)
    end
  end

  describe 'no information leaked about which accounts exist' do
    it 'uses the same message and delay for a real and an unknown username' do
      user = User.first
      4.times { described_class.record_failure(username, user:) }
      4.times { described_class.record_failure('definitely-not-a-user') }

      real = (described_class.check!(username) rescue $ERROR_INFO)
      fake = (described_class.check!('definitely-not-a-user') rescue $ERROR_INFO)

      expect(real.message).to eq(fake.message)
      expect(real.retry_after).to eq(fake.retry_after)
    end
  end

  describe 'the per-address layer' do
    let(:public_address) { '41.87.10.20' }

    before do
      # Small numbers keep these fast; the shipped defaults are 100 and 20.
      stub_const("#{described_class}::IP_FAILURE_THRESHOLD", 5)
      stub_const("#{described_class}::SWEEP_THRESHOLD", 3)
      described_class.instance_variable_set(:@exempt_ranges, nil)
    end

    def fail_from(address, times: 1, name: nil)
      times.times do |i|
        described_class.record_failure(name || "user_#{i}_#{SecureRandom.hex(2)}", remote_address: address)
      end
    end

    describe 'the ceiling' do
      it 'blocks an address once it crosses the failure threshold' do
        fail_from(public_address, times: 5)

        expect(described_class.retry_after('someone-else', remote_address: public_address))
          .to eq(described_class::IP_BLOCK_DURATION.to_i)
      end

      it 'leaves a clean username alone until the address crosses it' do
        fail_from(public_address, times: 4)

        expect(described_class.retry_after('someone-else', remote_address: public_address)).to be_nil
      end

      it 'rejects with exactly the same error as a username back-off' do
        fail_from(public_address, times: 5)

        expect { described_class.check!('someone-else', remote_address: public_address) }
          .to raise_error(TooManyRequestsError, described_class::MESSAGE)
      end

      it 'expires the address counter with the block, so one later failure does not re-block' do
        fail_from(public_address, times: 5)

        expect(redis.ttl("#{described_class::KEY_PREFIX}ip:fails:#{public_address}"))
          .to eq(described_class::IP_BLOCK_DURATION.to_i)
      end

      it 'audits the block once, with the address attached' do
        expect { fail_from(public_address, times: 5) }
          .to change(Audited::Audit.where(action: 'address_blocked'), :count).by(1)

        audit = Audited::Audit.where(action: 'address_blocked').order(:id).last
        expect(audit.remote_address).to eq(public_address)
        expect(audit.audited_changes['failures']).to eq(5)
      end

      it 'does not trip on a whole facility making occasional mistakes' do
        # 50 staff behind one NAT address, one typo each, against the real
        # shipped threshold rather than the small one these specs use.
        stub_const("#{described_class}::IP_FAILURE_THRESHOLD", 100)

        fail_from(public_address, times: 50)

        expect(described_class.retry_after('anyone', remote_address: public_address)).to be_nil
      end

      it 'is cleared by an operator unlock' do
        fail_from(public_address, times: 5)

        described_class.unlock_address!(public_address)

        expect(described_class.retry_after('someone-else', remote_address: public_address)).to be_nil
      end
    end

    describe 'which addresses it applies to' do
      it 'ignores loopback, so an unconfigured reverse proxy cannot lock out everyone at once' do
        fail_from('127.0.0.1', times: 20)

        expect(described_class.retry_after('anyone', remote_address: '127.0.0.1')).to be_nil
      end

      it 'ignores private and link-local addresses by default' do
        ['10.1.2.3', '192.168.1.50', '172.16.0.9', '169.254.1.1'].each do |address|
          fail_from(address, times: 20)
          expect(described_class.retry_after('anyone', remote_address: address)).to be_nil
        end
      end

      it 'applies to private addresses once the proxy is trusted' do
        stub_const("#{described_class}::TRUST_PRIVATE_ADDRESSES", true)

        fail_from('10.1.2.3', times: 5)

        expect(described_class.retry_after('anyone', remote_address: '10.1.2.3'))
          .to eq(described_class::IP_BLOCK_DURATION.to_i)
      end

      it 'ignores a blank or unparseable address instead of bucketing it' do
        ['', nil, 'not-an-ip', '41.87.1.1, 10.0.0.1'].each do |address|
          expect { fail_from(address, times: 6) }.not_to raise_error
          expect(described_class.retry_after('anyone', remote_address: address)).to be_nil
        end
      end

      it 'exempts an allowlisted address' do
        stub_const("#{described_class}::EXEMPT_ADDRESSES", "8.8.8.8,#{public_address}")
        described_class.instance_variable_set(:@exempt_ranges, nil)

        fail_from(public_address, times: 6)

        expect(described_class.retry_after('anyone', remote_address: public_address)).to be_nil
      end

      it 'exempts an allowlisted CIDR range' do
        stub_const("#{described_class}::EXEMPT_ADDRESSES", '41.87.0.0/16')
        described_class.instance_variable_set(:@exempt_ranges, nil)

        fail_from(public_address, times: 6)

        expect(described_class.retry_after('anyone', remote_address: public_address)).to be_nil
      end

      it 'ignores an unparseable allowlist entry rather than failing closed' do
        stub_const("#{described_class}::EXEMPT_ADDRESSES", 'nonsense,41.87.0.0/16')
        described_class.instance_variable_set(:@exempt_ranges, nil)

        expect { described_class.retry_after('anyone', remote_address: public_address) }.not_to raise_error
      end
    end

    describe 'sweep detection' do
      it 'alerts when one address fails against many distinct usernames' do
        expect { fail_from(public_address, times: 3) }
          .to change(Audited::Audit.where(action: 'login_sweep_detected'), :count).by(1)
      end

      it 'alerts once per window, not once per attempt' do
        expect { fail_from(public_address, times: 4) }
          .to change(Audited::Audit.where(action: 'login_sweep_detected'), :count).by(1)
      end

      it 'does not count the same username twice' do
        expect { fail_from(public_address, times: 4, name: 'same-user') }
          .not_to change(Audited::Audit.where(action: 'login_sweep_detected'), :count)
      end

      it 'never blocks on its own - stuffing must not become a way to shut a facility down' do
        stub_const("#{described_class}::IP_FAILURE_THRESHOLD", 1_000)

        fail_from(public_address, times: 10)

        expect(described_class.retry_after('anyone', remote_address: public_address)).to be_nil
      end
    end

    describe 'independence of the two layers' do
      it 'does not let address failures throttle an untouched username' do
        fail_from(public_address, times: 4)

        expect(described_class.username_retry_after('quiet-user')).to be_nil
      end

      it 'does not let a successful login clear the address evidence' do
        fail_from(public_address, times: 5)

        described_class.record_success('some-user')

        expect(described_class.retry_after('some-user', remote_address: public_address))
          .to eq(described_class::IP_BLOCK_DURATION.to_i)
      end

      it 'reports on the account alone when asked with no address' do
        fail_from(public_address, times: 5)

        expect(described_class.retry_after('quiet-user', remote_address: nil)).to be_nil
      end

      it 'reports whichever wait is longer' do
        fail_from(public_address, times: 5)
        4.times { described_class.record_failure('busy-user', remote_address: nil) }

        # The address block (5 minutes) outlasts the username back-off (5s).
        expect(described_class.retry_after('busy-user', remote_address: public_address))
          .to eq(described_class::IP_BLOCK_DURATION.to_i)
      end
    end
  end

  describe 'self-cleaning' do
    # Nothing sweeps this state, so every key the service writes has to carry
    # its own expiry. A new key added without one would leak forever.
    it 'gives every key it writes a positive expiry' do
      stub_const("#{described_class}::IP_FAILURE_THRESHOLD", 3)
      stub_const("#{described_class}::SWEEP_THRESHOLD", 2)

      # Exercise every write path: back-off, lock, address counter, address
      # block, sweep set and sweep alert.
      described_class::LOCK_THRESHOLD.times { described_class.record_failure(username, remote_address: '41.87.10.20') }
      4.times { |i| described_class.record_failure("other_#{i}", remote_address: '41.87.10.20') }

      keys = redis.all_keys
      expect(keys).to include(
        a_string_matching(/fails:/), a_string_matching(/wait:/),
        a_string_matching(/ip:fails:/), a_string_matching(/ip:block:/),
        a_string_matching(/ip:users:/), a_string_matching(/ip:alert:/)
      )

      unexpiring = keys.reject { |key| redis.ttl(key).to_i.positive? }
      expect(unexpiring).to be_empty
    end

    it 'namespaces everything under one prefix, so operators can inspect and drop it' do
      described_class.record_failure(username, remote_address: '41.87.10.20')

      expect(redis.all_keys).to all(start_with(described_class::KEY_PREFIX))
    end
  end

  describe 'when Redis is unavailable' do
    before do
      allow(described_class).to receive(:with_redis).and_call_original
      allow(Sidekiq).to receive(:redis).and_raise(StandardError, 'connection refused')
    end

    it 'fails open rather than locking clinicians out' do
      expect { described_class.check!(username) }.not_to raise_error
      expect(described_class.retry_after(username)).to be_nil
    end

    it 'still writes the audit row' do
      expect { described_class.record_failure(username) }
        .to change(Audited::Audit.where(action: 'failed_login'), :count).by(1)
    end

    it 'does not block any address either' do
      20.times { described_class.record_failure(username, remote_address: '41.87.10.20') }

      expect(described_class.retry_after(username, remote_address: '41.87.10.20')).to be_nil
    end
  end
end
