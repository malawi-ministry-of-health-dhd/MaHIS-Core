# Ensure ActionCable channel classes are loaded in API-only deployments.
# Without this, subscribe frames may be accepted at socket level but never
# confirmed at channel level in some environments.
Rails.application.config.to_prepare do
  Dir[Rails.root.join("app/channels/**/*_channel.rb")].sort.each do |channel_file|
    require_dependency channel_file
  end
end
