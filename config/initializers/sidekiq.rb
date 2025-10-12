# config/initializers/sidekiq.rb

require 'sidekiq'
require 'sidekiq-cron'

Sidekiq.default_job_options = { 'retry' => true } # Retry indefinitely

Sidekiq.configure_server do |config|
  config.redis = { url: 'redis://localhost:6379/0', namespace: 'emr_api' }
end

Sidekiq.configure_client do |config|
  config.redis = { url: 'redis://localhost:6379/0', namespace: 'emr_api' }
end

schedule_file = "config/schedule.yml"

if File.exist?(schedule_file) && Sidekiq.server?
  Sidekiq::Cron::Job.load_from_hash YAML.load_file(schedule_file)
end
  