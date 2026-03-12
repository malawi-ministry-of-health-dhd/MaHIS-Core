# lib/tasks/couchdb_listeners.rake
namespace :couchdb do
  desc "Start CouchDB listeners for all databases"
  task start_all_listeners: :environment do
    sequential_configs = [
      {
        db_name: 'patients_records',
        processor_service: SavePatientRecordService.new,
        processor_method: :create_patient_record
      },
      {
        db_name: 'visits',
        processor_service: VisitService.new,
        processor_method: :create_update_visit
      },
      {
        db_name: 'stages',
        processor_service: StagesService.new,
        processor_method: :create_stage
      },
    ]

    Rails.logger.info("[CouchDB Listener] Starting sequential backfill: patients_records → visits → stages")

    # Phase 1: Sequential blocking backfill — each must finish before the next starts
    sequential_configs.each do |config|
      db_name = config[:db_name]
      Rails.logger.info("[CouchDB Listener] Backfilling #{db_name}...")

      listener = CouchdbChangesListener.new(**config)
      listener.process_all_unprocessed_documents  # already public, blocking

      Rails.logger.info("[CouchDB Listener] Backfill complete for #{db_name}.")
    end

    Rails.logger.info("[CouchDB Listener] All backfills done. Starting live change-feed listeners...")

    # Phase 2: Start live listeners (skip backfill on startup — already done above)
    CouchdbChangesListener.start_multiple_live_only(sequential_configs)
  end

  desc "Start listener for specific database"
  task :start_listener, [:db_name] => :environment do |task, args|
    db_name = args[:db_name]

    config_map = {
      'patients_records' => {
        processor_service: SavePatientRecordService.new,
        processor_method: :create_patient_record
      },
      'visits' => {
        processor_service: VisitService.new,
        processor_method: :create_update_visit
      },
      'stages' => {
        processor_service: StagesService.new,
        processor_method: :create_stage
      },
    }

    config = config_map[db_name]
    if config
      listener = CouchdbChangesListener.new(db_name: db_name, **config)
      listener.start
    else
      Rails.logger.error("No configuration found for database: #{db_name}")
    end
  end
end
