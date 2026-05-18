# frozen_string_literal: true

allowed_origins = ENV.fetch(
  'WEBAUTHN_ALLOWED_ORIGINS',
  'http://localhost:5173,http://127.0.0.1:5173'
).split(',').map(&:strip).reject(&:blank?)

WebAuthn.configure do |config|
  config.allowed_origins = allowed_origins
  config.rp_name = ENV.fetch('WEBAUTHN_RP_NAME', 'MAHIS')
  config.rp_id = ENV['WEBAUTHN_RP_ID'] if ENV['WEBAUTHN_RP_ID'].present?
  config.credential_options_timeout = 120_000
end
