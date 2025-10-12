# lib/tasks/couchdb_listeners.rake
namespace :couchdb do
  desc "Start CouchDB listeners for all databases"
  task start_all_listeners: :environment do
    database_configs = [
      {
        db_name: 'patients_records',
        processor_service: SavePatientRecordService.new,
        processor_method: :create_patient_record
      },
       {
        db_name: 'visits',
        processor_service: VisitsService.new,
        processor_method: :create_update_visit
      },
       {
        db_name: 'stages',
        processor_service: StagesService.new,
        processor_method: :create_stage
      },
    ]
    
    Rails.logger.info("Starting CouchDB listeners for #{database_configs.length} databases")
    CouchdbChangesListener.start_multiple(database_configs)
  end
  
  desc "Start listener for specific database"
  task :start_listener, [:db_name] => :environment do |task, args|
    db_name = args[:db_name]
    
    # Define your database-specific configurations
    config_map = {
      'patients_records' => {
        processor_service: SavePatientRecordService.new,
        processor_method: :create_patient_record
      },
    }
    
    config = config_map[db_name]
    if config
      listener = CouchdbChangesListener.new(
        db_name: db_name,
        **config
      )
      listener.start
    else
      Rails.logger.error("No configuration found for database: #{db_name}")
    end
  end
end

# ============================================
# 6. Running the Listeners
# ============================================

# Start all listeners:
# rails couchdb:start_all_listeners

# Start specific listener:
# rails couchdb:start_listener[patients_records]