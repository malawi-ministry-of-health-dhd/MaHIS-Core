# frozen_string_literal: true

require 'securerandom'
require 'webauthn'

module PasskeyAuthenticationService
  CHALLENGE_TTL = 10.minutes

  REGISTRATION_CHALLENGE_PROP   = 'passkey_registration_challenge'
  AUTHENTICATION_CHALLENGE_PROP = 'passkey_authentication_challenge'
  CREDENTIALS_PROP              = 'passkey_credentials'
  WEBAUTHN_ID_PROP              = 'webauthn_id'

  # Biometric-only policy: restrict ceremonies to the device's built-in platform
  # authenticator (Touch ID / Windows Hello / on-device fingerprint), which is the
  # one gated by biometrics. Combined with user_verification: 'required' this forces
  # the biometric/PIN check and removes the QR-code "use a phone" hybrid flow and
  # roaming security keys from the browser dialog. 'client-device' is the matching
  # WebAuthn L3 UI hint (ignored by browsers that don't support it).
  CREDENTIAL_HINTS = %w[client-device].freeze

  # Authentication (get) has no authenticator_attachment field, so we instead tag the
  # allowed credentials as living on the platform authenticator. Without transports the
  # browser assumes the credential might be on a phone and offers the QR/hybrid flow;
  # 'internal' keeps login on the on-device biometric (Touch ID / Windows Hello).
  PLATFORM_TRANSPORTS = %w[internal].freeze

  # A passkey is bound to the platform that created it: an Android credential
  # cannot be used by a browser and vice versa. Each platform therefore gets its
  # own allowance. Android permits two because a shared clinic device receives no
  # copy of a passkey synced through the clinician's personal Google account,
  # while a browser passkey syncs across that browser's own profile.
  PLATFORM_ANDROID = 'android'
  PLATFORM_WEB     = 'web'
  PLATFORM_SLOTS   = { PLATFORM_ANDROID => 2, PLATFORM_WEB => 1 }.freeze
  ANDROID_ORIGIN_PREFIX = 'android:apk-key-hash:'

  class << self
    def registration_options(user, platform: PLATFORM_WEB)
      platform = normalize_platform(platform)
      webauthn_id = ensure_webauthn_id!(user)

      options = WebAuthn::Credential.options_for_create(
        user: {
          id: webauthn_id,
          name: user.username,
          display_name: user.name || user.username
        },
        exclude: active_credentials(user).map { |c| c['id'] },
        authenticator_selection: {
          authenticator_attachment: 'platform',
          user_verification: 'required',
          resident_key: 'preferred'
        },
        attestation: 'none'
      )

      session_token = store_challenge(user, REGISTRATION_CHALLENGE_PROP, options.challenge, platform:)
      { session_token:, options: options.as_json.merge('hints' => CREDENTIAL_HINTS) }
    end

    def register(session_token:, credential:, nickname: nil)
      user, challenge, claimed_platform = consume_challenge!(session_token, REGISTRATION_CHALLENGE_PROP)
      webauthn_credential = WebAuthn::Credential.from_create(credential)
      webauthn_credential.verify(challenge, user_verification: true)

      # The verified clientDataJSON origin says which platform really performed the
      # ceremony, so the slot is never taken from a client-supplied label.
      platform = platform_from_origin(webauthn_credential.response.client_data.origin)
      if claimed_platform.present? && claimed_platform != platform
        raise WebAuthn::Error, "Passkey was created on #{platform} but #{claimed_platform} was requested"
      end
      unless slot_available?(user, platform)
        raise WebAuthn::Error,
              "This account already has the maximum number of #{platform} passkeys. " \
              'Ask an administrator to reset passkey login.'
      end

      new_cred = {
        'id'           => webauthn_credential.id,
        'public_key'   => webauthn_credential.public_key,
        'sign_count'   => webauthn_credential.sign_count.to_i,
        'nickname'     => nickname.presence || 'This device',
        'platform'     => platform,
        'transports'   => Array(credential[:transports] || credential['transports']).join(','),
        'last_used_at' => nil,
        'revoked_at'   => nil
      }

      credentials = load_credentials(user)
      credentials << new_cred
      save_credentials(user, credentials)

      user
    end

    def authentication_options(user, platform: PLATFORM_WEB)
      creds = credentials_for(user, normalize_platform(platform))
      raise ActiveRecord::RecordNotFound, 'No passkeys registered for this user' if creds.empty?

      options = WebAuthn::Credential.options_for_get(
        allow: creds.map { |c| c['id'] },
        user_verification: 'required'
      )

      json = options.as_json
      json[:allowCredentials]&.each { |descriptor| descriptor[:transports] = PLATFORM_TRANSPORTS }

      session_token = store_challenge(user, AUTHENTICATION_CHALLENGE_PROP, options.challenge)
      { session_token:, options: json.merge('hints' => CREDENTIAL_HINTS) }
    end

    def authenticate(session_token:, credential:)
      user, challenge = consume_challenge!(session_token, AUTHENTICATION_CHALLENGE_PROP)
      webauthn_credential = WebAuthn::Credential.from_get(credential)

      credentials = active_credentials(user)
      stored = credentials.find { |c| c['id'] == webauthn_credential.id }
      raise ActiveRecord::RecordNotFound, 'Passkey credential not found' unless stored

      webauthn_credential.verify(
        challenge,
        public_key: stored['public_key'],
        sign_count: stored['sign_count'],
        user_verification: true
      )

      stored['sign_count'] = webauthn_credential.sign_count.to_i
      stored['last_used_at'] = Time.current.iso8601
      save_credentials(user, credentials)

      user
    end

    # Whether the device now logging in should authenticate with a passkey it
    # already holds, or register one. A platform with no passkey always registers.
    # A platform with a free slot registers only when the client asks for it,
    # which it does after its authenticator reports it holds no usable passkey —
    # that is how a second, unsynced Android device enrols.
    def next_step_for(user, platform:, enroll_requested: false)
      platform = normalize_platform(platform)
      registered = credentials_for(user, platform)

      return :register if registered.empty?
      return :register if enroll_requested && registered.size < slot_limit(platform)

      :authenticate
    end

    def normalize_platform(value)
      value.to_s.strip.downcase == PLATFORM_ANDROID ? PLATFORM_ANDROID : PLATFORM_WEB
    end

    def platform_from_origin(origin)
      origin.to_s.start_with?(ANDROID_ORIGIN_PREFIX) ? PLATFORM_ANDROID : PLATFORM_WEB
    end

    def slot_limit(platform)
      PLATFORM_SLOTS.fetch(normalize_platform(platform), 1)
    end

    def slot_available?(user, platform)
      platform = normalize_platform(platform)
      credentials_for(user, platform).size < slot_limit(platform)
    end

    # Devices a superuser can see before deciding to reset, without exposing the
    # stored public keys or credential ids.
    def device_summaries(user)
      active_credentials(user).map do |credential|
        {
          nickname: credential['nickname'],
          platform: credential['platform'],
          transports: credential['transports'].presence,
          last_used_at: credential['last_used_at']
        }
      end
    end

    # Revokes every passkey a user has registered so their next login enrols the
    # device they are on. The extra security layer stays enabled — this is the
    # recovery path for a lost, wiped or replaced device, and the alternative is
    # switching the layer off entirely. Revoked entries are kept rather than
    # deleted so the history remains available for investigations.
    def revoke_all_credentials!(user, revoked_at: Time.current)
      credentials = load_credentials(user)
      revoked = credentials.count { |credential| credential['revoked_at'].blank? }
      return 0 if revoked.zero?

      credentials.each { |credential| credential['revoked_at'] ||= revoked_at.iso8601 }
      save_credentials(user, credentials)
      revoked
    end

    private

    def ensure_webauthn_id!(user)
      prop = UserProperty.find_or_initialize_by(user_id: user.user_id, property: WEBAUTHN_ID_PROP)
      prop.property_value = WebAuthn.generate_user_id if prop.property_value.blank?
      prop.save!
      prop.property_value
    end

    def load_credentials(user)
      prop = UserProperty.find_by(user_id: user.user_id, property: CREDENTIALS_PROP)
      return [] if prop.nil? || prop.property_value.blank?

      JSON.parse(prop.property_value)
    rescue JSON::ParserError
      []
    end

    def save_credentials(user, credentials)
      prop = UserProperty.find_or_initialize_by(user_id: user.user_id, property: CREDENTIALS_PROP)
      prop.property_value = credentials.to_json
      # UserProperty requires its user, and User is location-scoped through
      # Locatable, so an administrator managing someone at another facility would
      # fail that validation. Same reason `manageable_user` unscopes the lookup.
      User.unscoped { prop.save! }
    end

    def active_credentials(user)
      load_credentials(user).reject { |c| c['revoked_at'].present? }
    end

    def credentials_for(user, platform)
      active_credentials(user).select { |c| c['platform'] == platform }
    end

    # Embeds user_id in the token (as "<user_id>.<random>") so the correct
    # user_property row can be located on the return trip without a table scan.
    # urlsafe_base64 uses A-Za-z0-9-_ — no dots — so the split is unambiguous.
    def store_challenge(user, property, challenge, platform: nil)
      random = SecureRandom.urlsafe_base64(24)
      prop = UserProperty.find_or_initialize_by(user_id: user.user_id, property:)
      prop.property_value = { token: random, challenge: challenge, platform: platform,
                              expires_at: (Time.current + CHALLENGE_TTL).iso8601 }.to_json
      prop.save!
      "#{user.user_id}.#{random}"
    end

    def consume_challenge!(session_token, property)
      user_id_str, random = session_token.to_s.split('.', 2)
      raise ActiveRecord::RecordNotFound, 'Invalid session token' if user_id_str.blank? || random.blank?

      prop = UserProperty.find_by!(user_id: user_id_str.to_i, property:)
      data = JSON.parse(prop.property_value)

      raise ActiveRecord::RecordNotFound, 'Passkey challenge expired' if Time.parse(data['expires_at']) <= Time.current
      raise ActiveRecord::RecordNotFound, 'Invalid session token' unless data['token'] == random

      prop.destroy
      user = User.find(user_id_str.to_i)
      [user, data['challenge'], data['platform']]
    rescue JSON::ParserError
      raise ActiveRecord::RecordNotFound, 'Invalid session token'
    end
  end
end
