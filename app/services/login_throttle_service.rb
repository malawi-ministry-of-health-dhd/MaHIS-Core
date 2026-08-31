# frozen_string_literal: true

require 'ipaddr'

# Rate limits credential checks.
#
# Three layers, all expressed as a "wait" key with a TTL so that every rejection
# looks identical to the client:
#
#   1. Per-username progressive back-off - the first few consecutive failures
#      are free, then each one costs a longer delay.
#   2. Per-username soft lock - a longer, still auto-expiring wait.
#   3. Per-address ceiling - a deliberately high cap that only automated floods
#      can reach, plus alert-only detection of one address sweeping many
#      usernames (credential stuffing, which no per-username counter can see).
#
# The username counter is keyed on the string as submitted - including usernames
# that do not exist. Throttling only real accounts would turn the throttle
# itself into an account-existence oracle.
#
# Redis is best effort and this service FAILS OPEN: if Redis is unavailable
# logins proceed unthrottled rather than locking every clinician out of patient
# records. Audit rows are written to the database either way, so the open
# window is visible after the fact.
module LoginThrottleService
  KEY_PREFIX = 'auththrottle:'
  # Sliding window: the failure count is forgotten this long after the last
  # failure, and is cleared outright on a successful login.
  COUNTER_TTL = 15.minutes
  # Seconds a client must wait after its Nth consecutive failure. The first
  # three are free so an ordinary typo costs nothing.
  BACKOFF_SECONDS = { 4 => 5, 5 => 15, 6 => 30, 7 => 60, 8 => 60, 9 => 60 }.freeze
  # Failure count at which the account is locked instead of merely delayed.
  LOCK_THRESHOLD = 10
  # The lock expires on its own. An admin unlock exists but is never required:
  # nobody should need to find a superuser to get back into a clinical system.
  LOCK_DURATION = 15.minutes
  # Same cost as a real password check on the unknown-username path, so response
  # time does not reveal whether an account exists.
  TIMING_EQUALIZER_SALT = 'login-throttle-timing-equalizer'

  # Deliberately says nothing about whether the account exists, whether the
  # password was right, or whether this is a back-off, a lock or an address
  # ceiling.
  MESSAGE = 'Too many failed login attempts. Please try again later.'

  # --- Layer 3: per-address ---
  #
  # A facility NATs its entire staff behind one public address, and rural sites
  # can share a carrier CGNAT range, so this ceiling is set far above plausible
  # human use. It exists to stop automated floods, not typos: tripping it takes
  # every clinician at that site offline, which is why the number is blunt and
  # the block is short.
  IP_FAILURE_WINDOW = 5.minutes
  IP_FAILURE_THRESHOLD = ENV.fetch('LOGIN_THROTTLE_IP_THRESHOLD', 100).to_i
  IP_BLOCK_DURATION = 5.minutes

  # Credential stuffing tries one password against many accounts, so it never
  # trips a per-username counter. Counting how many DISTINCT usernames one
  # address has failed against does see it. This layer only ALERTS: blocking on
  # it would hand anyone who knows enough usernames a way to take a facility
  # offline.
  SWEEP_WINDOW = 10.minutes
  SWEEP_THRESHOLD = ENV.fetch('LOGIN_THROTTLE_SWEEP_THRESHOLD', 20).to_i

  # Addresses (single or CIDR, comma separated) exempt from layer 3 - a known
  # facility egress or a monitoring probe. NIST SP 800-63B names allowlisting as
  # a legitimate throttling mitigation.
  EXEMPT_ADDRESSES = ENV.fetch('LOGIN_THROTTLE_EXEMPT_IPS', '')

  # Loopback and private source addresses are IGNORED by layer 3 by default: if
  # the reverse proxy does not forward the real client address, every request in
  # the country arrives as 127.0.0.1, and blocking that one bucket would lock
  # out every user at once. Set this only once the proxy is confirmed to send
  # X-Forwarded-For, or for a deployment whose clients really are on the LAN.
  TRUST_PRIVATE_ADDRESSES = ENV.fetch('LOGIN_THROTTLE_TRUST_PRIVATE_IPS', 'false') == 'true'

  module_function

  # Raises TooManyRequestsError when this username, or the address it is coming
  # from, is still inside a wait window. Called before any password comparison.
  def check!(username, remote_address: current_remote_address)
    seconds = retry_after(username, remote_address:)
    return if seconds.nil?

    raise TooManyRequestsError.new(MESSAGE, retry_after: seconds)
  end

  # Seconds remaining before the next attempt is allowed, or nil when allowed
  # now. Pass remote_address: nil to ask about the username alone - what an
  # administrator looking up someone else's account wants to know.
  def retry_after(username, remote_address: current_remote_address)
    [username_retry_after(username), address_retry_after(remote_address)].compact.max
  end

  def locked?(username, remote_address: current_remote_address)
    !retry_after(username, remote_address:).nil?
  end

  def username_retry_after(username)
    key = normalize(username)
    return nil if key.blank?

    positive_ttl(wait_key(key))
  end

  def address_retry_after(remote_address)
    address = throttleable_address(remote_address)
    return nil unless address

    positive_ttl(address_block_key(address))
  end

  # Counts a failed credential check and applies the resulting delay or lock.
  # `user` is nil when the username does not exist.
  def record_failure(username, user: nil, remote_address: current_remote_address)
    key = normalize(username)
    return if key.blank?

    # Two calls rather than a MULTI: Sidekiq's redis-client wrapper has no real
    # transaction support, and a missed EXPIRE only widens the window slightly.
    count = with_redis do |redis|
      counted = redis.incr(counter_key(key))
      redis.expire(counter_key(key), COUNTER_TTL.to_i)
      counted
    end

    locked = count.present? && count >= LOCK_THRESHOLD
    apply_wait(key, count) if count.present?
    audit_failure(username, user, count, locked:)
    record_address_failure(username, remote_address)
  end

  # Clears the username's failure state after a successful login. Address-level
  # state is deliberately left alone: one valid credential must not let an
  # attacker reset the evidence of a flood from that address.
  def record_success(username)
    key = normalize(username)
    return if key.blank?

    with_redis do |redis|
      redis.del(counter_key(key), wait_key(key))
    end
  end

  # Administrative unlock. Not required for recovery - locks expire on their own.
  def unlock!(username)
    record_success(username)
  end

  # Equalises the cost of the unknown-username path with a real password check.
  def equalize_timing(password)
    Digest::SHA512.hexdigest("#{password}#{TIMING_EQUALIZER_SALT}")
    nil
  end

  # Counts a failure against the originating address and blocks it once the
  # ceiling is reached. Silently does nothing when the address cannot be trusted
  # (see TRUST_PRIVATE_ADDRESSES) - a wrong bucket is worse than no bucket.
  def record_address_failure(username, remote_address)
    address = throttleable_address(remote_address)
    return unless address

    count = with_redis do |redis|
      counted = redis.incr(address_counter_key(address))
      redis.expire(address_counter_key(address), IP_FAILURE_WINDOW.to_i)
      counted
    end
    return if count.blank?

    track_sweep(username, address)
    return if count < IP_FAILURE_THRESHOLD

    with_redis do |redis|
      redis.set(address_block_key(address), count, ex: IP_BLOCK_DURATION.to_i)
      # Expire the counter with the block, so an address that waits one out is
      # not re-blocked by its next single failure.
      redis.expire(address_counter_key(address), IP_BLOCK_DURATION.to_i)
    end

    audit_address_event(
      address,
      'address_blocked',
      "Login blocked for #{address} after #{count} failed attempts in #{IP_FAILURE_WINDOW.inspect}",
      { 'failures' => count, 'blocked_for_seconds' => IP_BLOCK_DURATION.to_i }
    )
  end

  # Alert-only: one address failing against many distinct usernames is the shape
  # of credential stuffing. Raises no wait of its own.
  def track_sweep(username, address)
    name = normalize(username)
    return if name.blank?

    distinct = with_redis do |redis|
      redis.sadd(sweep_key(address), name)
      redis.expire(sweep_key(address), SWEEP_WINDOW.to_i)
      redis.scard(sweep_key(address))
    end
    return if distinct.blank? || distinct < SWEEP_THRESHOLD

    # One alert per window rather than one per attempt. INCR rather than SET NX
    # so this works the same through Sidekiq's redis-client wrapper.
    alerts = with_redis do |redis|
      counted = redis.incr(sweep_alert_key(address))
      redis.expire(sweep_alert_key(address), SWEEP_WINDOW.to_i)
      counted
    end
    return unless alerts == 1

    audit_address_event(
      address,
      'login_sweep_detected',
      "#{address} failed logins against #{distinct} distinct usernames in #{SWEEP_WINDOW.inspect}",
      { 'distinct_usernames' => distinct }
    )
  end

  # Clears an address block. Blocks expire on their own; this is for an operator
  # who does not want a wrongly-caught facility waiting it out.
  def unlock_address!(remote_address)
    address = remote_address.to_s.strip
    return if address.blank?

    with_redis do |redis|
      redis.del(address_counter_key(address), address_block_key(address),
                sweep_key(address), sweep_alert_key(address))
    end
  end

  # The address layer applies only to an address we can actually attribute to a
  # single client. Anything else - blank, malformed, loopback, private, exempt -
  # opts out entirely rather than being lumped into a shared bucket.
  def throttleable_address(remote_address)
    address = remote_address.to_s.strip
    return nil if address.blank?

    ip = IPAddr.new(address)
    return nil if !TRUST_PRIVATE_ADDRESSES && (ip.loopback? || ip.private? || ip.link_local?)
    return nil if exempt_address?(ip)

    address
  rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
    nil
  end

  def exempt_address?(ip)
    exempt_ranges.any? { |range| range.include?(ip) }
  end

  def exempt_ranges
    @exempt_ranges ||= EXEMPT_ADDRESSES.to_s.split(',').filter_map do |entry|
      IPAddr.new(entry.strip)
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      Rails.logger.warn("LoginThrottleService: ignoring unparseable exempt address '#{entry}'")
      nil
    end
  end

  def current_remote_address
    Audited.store[:current_remote_address]
  end

  def positive_ttl(key)
    ttl = with_redis { |redis| redis.ttl(key) }
    ttl.to_i.positive? ? ttl.to_i : nil
  end

  def apply_wait(key, count)
    locked = count >= LOCK_THRESHOLD
    seconds = locked ? LOCK_DURATION.to_i : BACKOFF_SECONDS[count]
    return if seconds.blank?

    with_redis do |redis|
      redis.set(wait_key(key), count, ex: seconds)
      # Expire the counter with the lock, so someone who waits out a lock gets a
      # fresh set of free attempts instead of being re-locked by one more typo.
      # Without this the two TTLs only line up by coincidence of the constants.
      redis.expire(counter_key(key), seconds) if locked
    end
  end

  # One immutable row per failed attempt in the shared `audits` table, so login
  # monitoring has something to read. Written outside the Redis call: the audit
  # trail must survive a Redis outage.
  #
  # For an unknown username there is nothing to attach the row to, so
  # auditable_id is left nil and the attempted username is still recorded -
  # enumeration sweeps stay visible.
  def audit_failure(username, user, count, locked:)
    action = locked ? 'account_locked' : 'failed_login'
    Rails.logger.warn("Login locked for '#{username}' after #{count} consecutive failures") if locked

    Audited::Audit.create!(
      auditable_type: 'User',
      auditable_id: user&.user_id,
      user_id: user&.user_id,
      username:,
      action:,
      audited_changes: {
        'username' => username.to_s,
        'consecutive_failures' => count,
        'locked_for_seconds' => locked ? LOCK_DURATION.to_i : nil
      }.compact,
      comment: locked ? "Account locked after #{count} consecutive failed logins" : "Failed login attempt (#{count})",
      remote_address: Audited.store[:current_remote_address],
      version: next_version(user),
      created_at: Time.current
    )
  rescue StandardError => e
    # An audit failure must not turn a wrong password into a 500.
    Rails.logger.error("Failed to audit login attempt for '#{username}': #{e.class}: #{e.message}")
  end

  # Address-level events have no user to attach to, so they are recorded against
  # the audits table with the address in remote_address and no auditable id.
  def audit_address_event(address, action, message, changes)
    Rails.logger.warn("LoginThrottleService: #{message}")

    Audited::Audit.create!(
      auditable_type: 'User',
      action:,
      audited_changes: changes.merge('remote_address' => address),
      comment: message,
      remote_address: address,
      version: 0,
      created_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error("Failed to audit #{action} for #{address}: #{e.class}: #{e.message}")
  end

  def next_version(user)
    return 0 unless user

    (Audited::Audit.where(auditable_type: 'User', auditable_id: user.user_id).maximum(:version) || 0) + 1
  end

  def counter_key(key)
    "#{KEY_PREFIX}fails:#{key}"
  end

  def address_counter_key(address)
    "#{KEY_PREFIX}ip:fails:#{address}"
  end

  def address_block_key(address)
    "#{KEY_PREFIX}ip:block:#{address}"
  end

  def sweep_key(address)
    "#{KEY_PREFIX}ip:users:#{address}"
  end

  def sweep_alert_key(address)
    "#{KEY_PREFIX}ip:alert:#{address}"
  end

  def wait_key(key)
    "#{KEY_PREFIX}wait:#{key}"
  end

  def normalize(username)
    username.to_s.strip.downcase
  end

  # Reuses Sidekiq's Redis pool, mirroring SyncProgress. Returns nil on any
  # Redis error - callers treat that as "no limit known", i.e. fail open.
  def with_redis
    if defined?(Sidekiq)
      Sidekiq.redis { |conn| yield conn }
    else
      yield fallback_redis
    end
  rescue StandardError => e
    Rails.logger.error("LoginThrottleService: Redis unavailable, failing open: #{e.class}: #{e.message}")
    nil
  end

  def fallback_redis
    @fallback_redis ||= Redis.new
  end
end
