# frozen_string_literal: true

require 'rails_helper'

# Integration-level cover for the throttle where it is actually wired in:
# UserService.authenticate_credentials, the single choke point behind
# auth/login, auth/confirm_supervision and UserService.login.
#
# These are as much regression tests as new-feature tests - the throttle sits
# directly in the login path, so the existing behaviours (correct password
# succeeds, wrong password returns nil, deactivated users are refused) have to
# keep working unchanged.
RSpec.describe UserService, '.authenticate_credentials with login throttling' do
  let(:password) { 'correct horse battery staple' }
  let(:salt) { SecureRandom.hex(8) }
  # Fresh per example: throttle state lives in real Redis and outlives both the
  # example and the run, so a fixed name here makes these order-dependent.
  let(:unknown_username) { "no-such-user-#{SecureRandom.hex(4)}" }

  let!(:user) do
    User.create!(
      username: "throttle_int_#{SecureRandom.hex(4)}",
      password: UserService.hash_password(password, salt),
      salt:,
      person: create(:person),
      creator: 1
    )
  end

  before do
    # Real Redis is not assumed available in every environment, and leftover
    # state between runs would make these order-dependent.
    LoginThrottleService.unlock!(user.username)
    allow(LoginThrottleService).to receive(:audit_failure)
  end

  # No `after` cleanup: unlock! goes through record_success, which some examples
  # set a strict message expectation on. The per-example `before` is enough, and
  # each example uses a fresh random username anyway.

  describe 'existing behaviour is unchanged' do
    it 'still authenticates a correct password' do
      expect(UserService.authenticate_credentials(user.username, password)).to eq(user)
    end

    it 'still returns nil for a wrong password rather than raising' do
      expect(UserService.authenticate_credentials(user.username, 'wrong')).to be_nil
    end

    it 'still returns nil for an unknown username' do
      expect(UserService.authenticate_credentials(unknown_username, password)).to be_nil
    end

    it 'still refuses a deactivated user with the right password' do
      user.update_columns(deactivated_on: Time.current)

      expect(UserService.authenticate_credentials(user.username, password)).to be_nil
    end

    it 'leaves token authentication completely untouched' do
      expect(LoginThrottleService).not_to receive(:check!)

      UserService.authenticate('a-token-that-does-not-exist')
    end
  end

  describe 'throttle wiring' do
    it 'checks the throttle before comparing any password' do
      expect(LoginThrottleService).to receive(:check!).with(user.username).ordered
      expect(UserService).not_to receive(:bart_authenticate)

      allow(LoginThrottleService).to receive(:check!)
        .and_raise(TooManyRequestsError.new('nope', retry_after: 30))

      expect { UserService.authenticate_credentials(user.username, password) }
        .to raise_error(TooManyRequestsError)
    end

    it 'counts a wrong password' do
      expect(LoginThrottleService).to receive(:record_failure).with(user.username, user: user)

      UserService.authenticate_credentials(user.username, 'wrong')
    end

    it 'counts an unknown username with no user attached' do
      expect(LoginThrottleService).to receive(:record_failure).with(unknown_username)

      UserService.authenticate_credentials(unknown_username, password)
    end

    it 'counts a deactivated user with a correct password as a failure' do
      user.update_columns(deactivated_on: Time.current)
      expect(LoginThrottleService).to receive(:record_failure)

      UserService.authenticate_credentials(user.username, password)
    end

    it 'clears the counter on a successful login' do
      expect(LoginThrottleService).to receive(:record_success).with(user.username)

      UserService.authenticate_credentials(user.username, password)
    end

    it 'blocks the fifth attempt after four wrong passwords, then lets a correct one through once the wait passes' do
      4.times { UserService.authenticate_credentials(user.username, 'wrong') }

      expect { UserService.authenticate_credentials(user.username, password) }
        .to raise_error(TooManyRequestsError) { |e| expect(e.retry_after).to eq(5) }

      # Simulate the wait elapsing rather than sleeping through it.
      LoginThrottleService.unlock!(user.username)
      expect(UserService.authenticate_credentials(user.username, password)).to eq(user)
    end

    it 'does not log the throttle rejection as an unexpected error' do
      allow(LoginThrottleService).to receive(:check!)
        .and_raise(TooManyRequestsError.new('nope', retry_after: 5))
      expect(Rails.logger).not_to receive(:error)

      expect { UserService.authenticate_credentials(user.username, password) }
        .to raise_error(TooManyRequestsError)
    end
  end

  describe 'UserService.login' do
    it 'propagates the throttle instead of returning a token' do
      allow(LoginThrottleService).to receive(:check!)
        .and_raise(TooManyRequestsError.new('nope', retry_after: 5))

      expect { UserService.login(user.username, password) }.to raise_error(TooManyRequestsError)
    end

    it 'still issues a token for valid credentials' do
      expect(UserService.login(user.username, password)[:token]).to be_present
    end
  end
end
