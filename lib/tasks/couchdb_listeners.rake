# lib/tasks/couchdb_listeners.rake

# Manually require the listener class since it's in lib/
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
    
    Rails.logger.info("Starting CouchDB listeners for #{database_configs.length} databases")
    
    @running = true
    @shutting_down = false
    threads = []
    
    # IMPORTANT: Lambda must accept signal parameter
    shutdown = lambda do |sig|
      return if @shutting_down
      @shutting_down = true
      @running = false
      
      STDOUT.puts "\nReceived signal #{sig}. Stopping listeners..."
      
      sleep 1
      
      threads.each do |t|
        t.kill if t.alive? rescue nil
      end
      
      STDOUT.puts "All listeners stopped."
      exit(0)
    end
    
    Signal.trap('SIGTERM', &shutdown)
    Signal.trap('SIGINT', &shutdown)
    
    begin
      database_configs.each do |config|
        listener = CouchdbChangesListener.new(
          db_name: config[:db_name],
          processor_service: config[:processor_service],
          processor_method: config[:processor_method]
        )
        
        thread = listener.start
        threads << thread
        Rails.logger.info("Started listener for #{config[:db_name]}")
      end
    rescue => e
      Rails.logger.error("Error starting listeners: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      exit(1)
    end
    
    Rails.logger.info("All #{threads.length} listeners started successfully")
    STDOUT.puts "CouchDB listeners running. Press Ctrl+C to stop."
    STDOUT.flush
    
    while @running
      sleep 5
      
      dead_threads = threads.reject(&:alive?)
      if dead_threads.any? && @running
        STDOUT.puts "Some listener threads died. Exiting..."
        Rails.logger.error("Some listener threads died. Exiting...")
        
        threads.each { |t| t.kill if t.alive? rescue nil }
        exit(1)
      end
    end
    
    threads.each { |t| t.join(5) rescue nil }
  end
  
  desc "Start listener for specific database"
  task :start_listener, [:db_name] => :environment do |task, args|
    db_name = args[:db_name]
    
    config_map = {
      'patients_records' => {
        processor_service: SavePatientRecordService.new,
        processor_method: :create_patient_record
      },
    }
    
    config = config_map[db_name]
    if config
      @running = true
      thread = nil
      
      shutdown = lambda do |sig|
        @running = false
        STDOUT.puts "\nShutting down listener for #{db_name}..."
        thread&.kill rescue nil
        exit(0)
      end
      
      Signal.trap('SIGTERM', &shutdown)
      Signal.trap('SIGINT', &shutdown)
      
      listener = CouchdbChangesListener.new(
        db_name: db_name,
        **config
      )
      
      thread = listener.start
      
      Rails.logger.info("Listener started for #{db_name}")
      STDOUT.puts "Listener running for #{db_name}. Press Ctrl+C to stop."
      
      while @running && thread&.alive?
        sleep 5
      end
      
      thread&.kill rescue nil
      Rails.logger.info("Listener stopped for #{db_name}")
    else
      Rails.logger.error("No configuration found for database: #{db_name}")
    end
  end
end