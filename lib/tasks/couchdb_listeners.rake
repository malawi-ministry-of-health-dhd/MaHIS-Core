# lib/tasks/couchdb_listeners.rake
require_relative '../couchdb_changes_listener'

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
    
    puts "Starting CouchDB listeners for #{database_configs.length} databases..."
    
    # Just call the class method - it handles everything
    CouchdbChangesListener.start_multiple(database_configs)
  end
end