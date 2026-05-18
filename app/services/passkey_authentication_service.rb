# frozen_string_literal: true

require 'securerandom'
require 'webauthn'

module PasskeyAuthenticationService
  CHALLENGE_TTL = 10.minutes

  class << self
    def registration_options(user)
      ensure_webauthn_id!(user)

      options = WebAuthn::Credential.options_for_create(
        user: {
          id: user.webauthn_id,
          name: user.username,
          display_name: user.name || user.username
        },
        exclude: user.passkey_credentials.active.pluck(:webauthn_id),
        authenticator_selection: {
          user_verification: 'required',
          resident_key: 'preferred'
        },
        attestation: 'none'
      )

      challenge = create_challenge(user, PasskeyChallenge::REGISTRATION, options.challenge)
      { session_token: challenge.token, options: options.as_json }
    end

    def register(session_token:, credential:, nickname: nil)
      challenge = find_challenge!(session_token, PasskeyChallenge::REGISTRATION)
      webauthn_credential = WebAuthn::Credential.from_create(credential)
      webauthn_credential.verify(challenge.challenge, user_verification: true)

      passkey = challenge.user.passkey_credentials.create!(
        webauthn_id: webauthn_credential.id,
        public_key: webauthn_credential.public_key,
        sign_count: webauthn_credential.sign_count,
        nickname: nickname.presence || 'This device',
        transports: Array(credential[:transports] || credential['transports']).join(',')
      )

      challenge.destroy
      passkey
    end

    def authentication_options(user)
      credentials = user.passkey_credentials.active
      raise ActiveRecord::RecordNotFound, 'No passkeys registered for this user' if credentials.empty?

      options = WebAuthn::Credential.options_for_get(
        allow: credentials.pluck(:webauthn_id),
        user_verification: 'required'
      )

      challenge = create_challenge(user, PasskeyChallenge::AUTHENTICATION, options.challenge)
      { session_token: challenge.token, options: options.as_json }
    end

    def authenticate(session_token:, credential:)
      challenge = find_challenge!(session_token, PasskeyChallenge::AUTHENTICATION)
      webauthn_credential = WebAuthn::Credential.from_get(credential)
      stored_credential = challenge.user.passkey_credentials.active.find_by!(webauthn_id: webauthn_credential.id)

      webauthn_credential.verify(
        challenge.challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count,
        user_verification: true
      )

      stored_credential.update!(
        sign_count: webauthn_credential.sign_count,
        last_used_at: Time.current
      )
      challenge.destroy
      challenge.user
    end

    def required_for?(user)
      user.passkey_credentials.active.exists?
    end

    private

    def ensure_webauthn_id!(user)
      return if user.webauthn_id.present?

      user.update!(webauthn_id: WebAuthn.generate_user_id)
    end

    def create_challenge(user, ceremony, challenge)
      user.passkey_challenges.where(ceremony:).delete_all
      user.passkey_challenges.create!(
        token: SecureRandom.urlsafe_base64(32),
        challenge:,
        ceremony:,
        expires_at: Time.current + CHALLENGE_TTL
      )
    end

    def find_challenge!(token, ceremony)
      challenge = PasskeyChallenge.active.find_by!(token:, ceremony:)
      challenge.tap(&:destroy) if challenge.expired?
      raise ActiveRecord::RecordNotFound, 'Passkey challenge expired' if challenge.expired?

      challenge
    end
  end
end
