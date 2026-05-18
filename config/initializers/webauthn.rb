# frozen_string_literal: true

WebAuthn.configure do |config|
  config.allowed_origins = ENV['WEBAUTHN_ALLOWED_ORIGINS']
    &.split(',')&.map(&:strip)&.reject(&:blank?) || ->(_origin) { true }
  config.rp_name = ENV.fetch('WEBAUTHN_RP_NAME', 'MAHIS')
  config.rp_id = ENV.fetch('WEBAUTHN_RP_ID', 'localhost')
  config.credential_options_timeout = 120_000
end
