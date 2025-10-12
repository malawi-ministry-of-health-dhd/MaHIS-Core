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
    
    # Set up signal handlers for graceful shutdown
    @running = true
    
    Signal.trap('SIGTERM') do
      Rails.logger.info("Received SIGTERM, shutting down gracefully...")
      @running = false
    end
    
    Signal.trap('SIGINT') do
      Rails.logger.info("Received SIGINT, shutting down gracefully...")
      @running = false
    end
    
    # Start the listeners
    threads = CouchdbChangesListener.start_multiple(database_configs)
    
    Rails.logger.info("All listeners started successfully")
    puts "CouchDB listeners running. Press Ctrl+C to stop."
    
    # Keep the main process alive
    # Check if threads are still alive and if we should keep running
    while @running
      sleep 5
      
      # Check if any threads have died
      if threads.is_a?(Array)
        dead_threads = threads.reject(&:alive?)
        if dead_threads.any?
          Rails.logger.error("Some listener threads have died. Exiting...")
          break
        end
      end
    end
    
    # Cleanup: give threads time to finish
    Rails.logger.info("Waiting for listeners to finish...")
    if threads.is_a?(Array)
      threads.each do |thread|
        thread.join(5) # Wait up to 5 seconds for each thread
      end
    end
    
    Rails.logger.info("All listeners stopped")
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
      # Set up signal handlers
      @running = true
      
      Signal.trap('SIGTERM') do
        Rails.logger.info("Received SIGTERM, shutting down...")
        @running = false
      end
      
      Signal.trap('SIGINT') do
        Rails.logger.info("Received SIGINT, shutting down...")
        @running = false
      end
      
      listener = CouchdbChangesListener.new(
        db_name: db_name,
        **config
      )
      
      thread = listener.start
      
      Rails.logger.info("Listener started for #{db_name}")
      puts "Listener running for #{db_name}. Press Ctrl+C to stop."
      
      # Keep running
      while @running && thread&.alive?
        sleep 5
      end
      
      thread&.join(5)
      Rails.logger.info("Listener stopped for #{db_name}")
    else
      Rails.logger.error("No configuration found for database: #{db_name}")
    end
  end
end