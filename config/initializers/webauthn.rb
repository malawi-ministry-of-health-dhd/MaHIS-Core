# frozen_string_literal: true

WebAuthn.configure do |config|
  rp_id = ENV.fetch('WEBAUTHN_RP_ID', 'localhost')
  web_origins = ENV['WEBAUTHN_ALLOWED_ORIGINS']
    &.split(',')&.map(&:strip)&.reject(&:blank?) ||
    ["http://#{rp_id}", "https://#{rp_id}",
     "http://#{rp_id}:3000", "https://#{rp_id}:3000",
     "http://#{rp_id}:5173", "https://#{rp_id}:5173"]

  # Android's Credential Manager reports the calling app's signing certificate
  # instead of a web origin, so the MaHIS app's hash has to be allowed too.
  # Hashes may be listed with or without the 'android:apk-key-hash:' prefix.
  android_origins = ENV['WEBAUTHN_ANDROID_APK_KEY_HASHES'].to_s
    .split(',').map(&:strip).reject(&:blank?)
    .map { |hash| hash.start_with?('android:apk-key-hash:') ? hash : "android:apk-key-hash:#{hash}" }

  config.allowed_origins = web_origins + android_origins
  config.rp_name = ENV.fetch('WEBAUTHN_RP_NAME', 'MAHIS')
  config.rp_id = rp_id
  config.credential_options_timeout = 120_000
end
