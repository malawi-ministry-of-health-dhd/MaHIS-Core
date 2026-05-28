# frozen_string_literal: true

# Sidekiq deserializes worker class names from Redis in fresh worker
# processes. Load the Sync namespace and its workers explicitly so queued jobs
# like "Sync::BulkPatientRecordSyncJob" never depend on another request or rake
# task touching the namespace first.
Rails.application.config.to_prepare do
  require_dependency Rails.root.join('app/jobs/sync.rb').to_s
  require_dependency Rails.root.join('app/jobs/sync/base_sync_job.rb').to_s

  Dir[Rails.root.join('app/jobs/sync/*_job.rb')].sort.each do |job_file|
    require_dependency job_file.to_s
  end
end
