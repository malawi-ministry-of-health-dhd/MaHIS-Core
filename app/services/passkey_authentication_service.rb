# frozen_string_literal: true

require 'securerandom'
require 'webauthn'

module PasskeyAuthenticationService
  CHALLENGE_TTL = 10.minutes

  REGISTRATION_CHALLENGE_PROP   = 'passkey_registration_challenge'
  AUTHENTICATION_CHALLENGE_PROP = 'passkey_authentication_challenge'
  CREDENTIALS_PROP              = 'passkey_credentials'
  WEBAUTHN_ID_PROP              = 'webauthn_id'

  class << self
    def registration_options(user)
      webauthn_id = ensure_webauthn_id!(user)

      options = WebAuthn::Credential.options_for_create(
        user: {
          id: webauthn_id,
          name: user.username,
          display_name: user.name || user.username
        },
        exclude: active_credentials(user).map { |c| c['id'] },
        authenticator_selection: {
          user_verification: 'required',
          resident_key: 'preferred'
        },
        attestation: 'none'
      )

      session_token = store_challenge(user, REGISTRATION_CHALLENGE_PROP, options.challenge)
      { session_token:, options: options.as_json }
    end

    def register(session_token:, credential:, nickname: nil)
      user, challenge = consume_challenge!(session_token, REGISTRATION_CHALLENGE_PROP)
      webauthn_credential = WebAuthn::Credential.from_create(credential)
      webauthn_credential.verify(challenge, user_verification: true)

      new_cred = {
        'id'           => webauthn_credential.id,
        'public_key'   => webauthn_credential.public_key,
        'sign_count'   => webauthn_credential.sign_count.to_i,
        'nickname'     => nickname.presence || 'This device',
        'transports'   => Array(credential[:transports] || credential['transports']).join(','),
        'last_used_at' => nil,
        'revoked_at'   => nil
      }

      credentials = load_credentials(user)
      credentials << new_cred
      save_credentials(user, credentials)

      user
    end

    def authentication_options(user)
      creds = active_credentials(user)
      raise ActiveRecord::RecordNotFound, 'No passkeys registered for this user' if creds.empty?

      options = WebAuthn::Credential.options_for_get(
        allow: creds.map { |c| c['id'] },
        user_verification: 'required'
      )

      session_token = store_challenge(user, AUTHENTICATION_CHALLENGE_PROP, options.challenge)
      { session_token:, options: options.as_json }
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

    def required_for?(user)
      active_credentials(user).any?
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
      prop.save!
    end

    def active_credentials(user)
      load_credentials(user).reject { |c| c['revoked_at'].present? }
    end

    # Embeds user_id in the token (as "<user_id>.<random>") so the correct
    # user_property row can be located on the return trip without a table scan.
    # urlsafe_base64 uses A-Za-z0-9-_ — no dots — so the split is unambiguous.
    def store_challenge(user, property, challenge)
      random = SecureRandom.urlsafe_base64(24)
      prop = UserProperty.find_or_initialize_by(user_id: user.user_id, property:)
      prop.property_value = { token: random, challenge: challenge, expires_at: (Time.current + CHALLENGE_TTL).iso8601 }.to_json
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
      [user, data['challenge']]
    rescue JSON::ParserError
      raise ActiveRecord::RecordNotFound, 'Invalid session token'
    end
  end
end
