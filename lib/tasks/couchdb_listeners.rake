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
    
    # Start the listeners
    threads = CouchdbChangesListener.start_multiple(database_configs)
    
    Rails.logger.info("All listeners started successfully")
    puts "CouchDB listeners running. Press Ctrl+C to stop."
    
    # Set up signal handlers for graceful shutdown
    shutdown = lambda do
      puts "\nShutting down listeners..."
      
      # Kill all threads
      if threads.is_a?(Array)
        threads.each do |thread|
          thread.kill if thread.alive?
        end
      end
      
      exit(0)
    end
    
    Signal.trap('SIGTERM', &shutdown)
    Signal.trap('SIGINT', &shutdown)
    
    # Keep the main process alive and monitor threads
    loop do
      sleep 5
      
      # Check if any threads have died
      if threads.is_a?(Array)
        dead_threads = threads.reject(&:alive?)
        if dead_threads.any?
          puts "Some listener threads have died. Exiting..."
          Rails.logger.error("Some listener threads have died. Exiting...")
          exit(1)
        end
      end
    end
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
      
      thread = listener.start
      
      Rails.logger.info("Listener started for #{db_name}")
      puts "Listener running for #{db_name}. Press Ctrl+C to stop."
      
      # Set up signal handlers
      shutdown = lambda do
        puts "\nShutting down listener for #{db_name}..."
        thread&.kill if thread&.alive?
        exit(0)
      end
      
      Signal.trap('SIGTERM', &shutdown)
      Signal.trap('SIGINT', &shutdown)
      
      # Keep running
      loop do
        sleep 5
        unless thread&.alive?
          puts "Listener thread died. Exiting..."
          exit(1)
        end
      end
    else
      Rails.logger.error("No configuration found for database: #{db_name}")
    end
  end
end