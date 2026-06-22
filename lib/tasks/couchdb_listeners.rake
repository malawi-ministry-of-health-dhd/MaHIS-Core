# lib/tasks/couchdb_listeners.rake
require Rails.root.join('lib', 'facility_dde_activation_listener').to_s

module CouchdbListenerRakeLogging
  LISTENER_LOG_TAGS = ['[CouchDB Listener]', '[Facility DDE Listener]'].freeze

  class StdoutLogDevice
    def write(message)
      return unless LISTENER_LOG_TAGS.any? { |tag| message.include?(tag) }

      $stdout.write(message)
      $stdout.flush
    end

    def close; end
  end

  module_function

  def enable_stdout!
    return if @stdout_enabled
    return unless Rails.logger.respond_to?(:broadcast_to)

    stdout_logger = ActiveSupport::Logger.new(StdoutLogDevice.new)
    stdout_logger.level = Rails.logger.level
    stdout_logger.formatter = Rails.logger.formatter
    Rails.logger.broadcast_to(stdout_logger)
    @stdout_enabled = true
  end
end

namespace :couchdb do
  desc 'Start CouchDB listeners for all databases'
  task start_all_listeners: :environment do
    CouchdbListenerRakeLogging.enable_stdout!

    # COUCH_LISTENER_FAN_OUT=true makes the listeners enqueue Sync::CouchIngestJob
    # per change instead of processing inline (recommended on TiDB). Default false.
    fan_out = ENV.fetch('COUCH_LISTENER_FAN_OUT', 'false').to_s.strip.casecmp('true').zero?
    db_names = CouchdbChangesListener::PROCESSORS.keys

    Rails.logger.info("[CouchDB Listener] Starting sequential backfill (fan_out=#{fan_out}): #{db_names.join(' → ')}")

    # Phase 1: Sequential blocking backfill — each must finish before the next starts.
    # In fan_out mode this just enqueues the backlog (fast); the workers drain it.
    db_names.each do |db_name|
      Rails.logger.info("[CouchDB Listener] Backfilling #{db_name}...")
      CouchdbChangesListener.build(db_name, fan_out: fan_out).process_all_unprocessed_documents
      Rails.logger.info("[CouchDB Listener] Backfill complete for #{db_name}.")
    end

    Rails.logger.info('[CouchDB Listener] All backfills done. Starting live change-feed listeners...')

    Thread.new { FacilityDdeActivationListener.new.start }

    # Phase 2: Start live listeners (skip backfill on startup — already done above)
    CouchdbChangesListener.start_multiple_live_only(db_names, fan_out: fan_out)
  end

  desc 'Start listener for specific database'
  task :start_listener, [:db_name] => :environment do |_task, args|
    CouchdbListenerRakeLogging.enable_stdout!

    db_name = args[:db_name]
    fan_out = ENV.fetch('COUCH_LISTENER_FAN_OUT', 'false').to_s.strip.casecmp('true').zero?

    if db_name == 'facilities'
      FacilityDdeActivationListener.new.start
    elsif CouchdbChangesListener::PROCESSORS.key?(db_name)
      CouchdbChangesListener.build(db_name, fan_out: fan_out).start
    else
      Rails.logger.error("No configuration found for database: #{db_name}")
    end
  end
end
