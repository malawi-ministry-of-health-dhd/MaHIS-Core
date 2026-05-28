namespace :sync do
  desc "Run all sync jobs in parallel"
  task all: :environment do
    jobs = [
      Sync::BatchPatientSyncJob,
      Sync::FacilitySyncJob,
      Sync::SpecimenSyncJob,
      Sync::VisitSyncJob,
      Sync::StageSyncJob,
      Sync::StockSyncJob,
      Sync::TestResultIndicatorsSyncJob,
      Sync::TestTypesSyncJob,
      Sync::ConceptNameSyncJob,
      Sync::ConceptSetSyncJob,
      Sync::DistrictSyncJob,
      Sync::DrugSyncJob,
      Sync::ProgramSyncJob,
      Sync::RelationshipTypeSyncJob,
      Sync::TraditionalAuthoritySyncJob,
      Sync::VillageSyncJob,
      Sync::DdeIdsSyncJob,
      Sync::DiagnosisSyncJob,
      Sync::WardSyncJob,
      Sync::SectionSyncJob,
      Sync::RolesPermissionsSyncJob,
      Sync::RegimenIngredientSyncJob,
      Sync::DepartmentSyncJob,
      Sync::CustomRegimenIngredientSyncJob,
      Sync::GlobalPropertySyncJob,
      Sync::UserPropertySyncJob,
      Sync::MnhStatsSyncJob,
      Sync::RegimenExtraSyncJob,
      Sync::RegimenStarterPackSyncJob,
      Sync::ArvDrugSyncJob
    ]

    # Fresh run: clear any stale progress so the bars start from zero.
    SyncProgress.reset_all!

    jobs.each(&:perform_async)
    puts "✅ Enqueued #{jobs.size} sync jobs in parallel."

    # WATCH=0 (or NO_WATCH=1) just enqueues without the live dashboard.
    if ENV['WATCH'] == '0' || ENV['NO_WATCH'] == '1'
      puts 'Run `rails sync:progress` to watch progress.'
    else
      puts 'Watching progress (Ctrl-C to stop watching; sync keeps running)...'
      sleep 1 # give the first jobs a moment to register their totals
      SyncDashboard.new.watch
    end
  end

  desc 'Watch live progress of an in-flight sync (tables + index builds)'
  task progress: :environment do
    if SyncProgress.snapshot.empty?
      puts 'No active sync found. Start one with `rails sync:all`.'
    else
      SyncDashboard.new.watch
    end
  end

  desc "Run a specific sync job by name. Example: rails sync:run[StageSyncJob]"
  task :run, [:job_name] => :environment do |t, args|
    if args[:job_name].blank?
      puts "⚠️  Please provide a job name. Example: rails sync:run[StageSyncJob]"
      next
    end

    begin
      job_class = "Sync::#{args[:job_name]}".constantize
      job_class.perform_async
      puts "✅ Enqueued #{job_class}"
    rescue NameError
      puts "❌ Job Sync::#{args[:job_name]} not found."
    end
  end
end


# sync all records with couchDB
# rails sync:all

# Run only one job (e.g. StageSyncJob)
# rails "sync:run[StageSyncJob]"
