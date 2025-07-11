namespace :sync do
  desc "Run batch patient sync job"
  task batch: :environment do
    BatchPatientSyncJob.new.perform()
  end
end