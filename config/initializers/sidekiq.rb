require 'sidekiq'
require 'sidekiq-cron'
require 'sidekiq-unique-jobs'

# Global job defaults
Sidekiq.default_job_options = {
  'retry' => true,
  'lock' => :until_executed,
  'lock_ttl' => 30.minutes.to_i
}

Sidekiq.configure_server do |config|
  config.redis = { url: 'redis://localhost:6379/0' }

  # Unique job middleware
  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end

  config.server_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Server
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: 'redis://localhost:6379/0' }

  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end
end

schedule_file = "config/schedule.yml"

if File.exist?(schedule_file) && Sidekiq.server?
  Sidekiq::Cron::Job.load_from_hash YAML.load_file(schedule_file)
end