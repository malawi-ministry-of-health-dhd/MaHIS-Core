# frozen_string_literal: true

WebAuthn.configure do |config|
  rp_id = ENV.fetch('WEBAUTHN_RP_ID', 'localhost')
  config.allowed_origins = ENV['WEBAUTHN_ALLOWED_ORIGINS']
    &.split(',')&.map(&:strip)&.reject(&:blank?) ||
    ["http://#{rp_id}", "https://#{rp_id}",
     "http://#{rp_id}:3000", "https://#{rp_id}:3000",
     "http://#{rp_id}:5173", "https://#{rp_id}:5173"]
  config.rp_name = ENV.fetch('WEBAUTHN_RP_NAME', 'MAHIS')
  config.rp_id = rp_id
  config.credential_options_timeout = 120_000
end
