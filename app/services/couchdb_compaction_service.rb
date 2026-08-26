# frozen_string_literal: true

require 'json'
require 'rest-client'
require 'timeout'
require 'uri'

# Runs server-side CouchDB maintenance outside the request path.
#
# Automatic CouchDB "smoosh" channels are disabled when Sidekiq starts. This
# service then compacts one database/index at a time during the nightly window,
# avoiding the parallel daytime work that can exhaust Docker memory.
class CouchdbCompactionService
  include CouchdbSync

  DEFAULT_DATABASES = %w[patients_records].freeze
  DEFAULT_POLL_INTERVAL_SECONDS = 5
  DEFAULT_TIMEOUT_SECONDS = 6.hours.to_i
  DEFAULT_START_GRACE_SECONDS = 10
  DEFAULT_MIN_RECLAIMABLE_BYTES = 64.megabytes
  DEFAULT_MIN_FILE_TO_ACTIVE_RATIO = 1.5

  def self.disable_automatic_compaction!(logger: Rails.logger)
    new(logger:).disable_automatic_compaction!
  end

  def self.run!(logger: Rails.logger)
    new(logger:).run!
  end

  def initialize(
    logger: Rails.logger,
    sleeper: ->(seconds) { sleep(seconds) },
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  )
    @logger = logger
    @sleeper = sleeper
    @clock = clock
  end

  def disable_automatic_compaction!
    return false unless couchdb_configured?

    %w[db_channels view_channels].each do |setting|
      RestClient.put(
        couchdb_url('_node', '_local', '_config', 'smoosh', setting),
        JSON.generate(''),
        json_headers
      )
    end

    @logger&.info('[CouchDB Compaction] Disabled continuous smoosh database and view channels')
    true
  end

  def run!
    return false unless couchdb_configured?

    disable_automatic_compaction!
    databases.each { |database| compact_database_and_indexes!(database) }
    true
  end

  private

  def databases
    configured = ENV.fetch('COUCHDB_NIGHTLY_COMPACTION_DATABASES', DEFAULT_DATABASES.join(','))

    configured
      .split(',')
      .map(&:strip)
      .reject(&:blank?)
      .tap do |names|
        invalid = names.reject { |name| name.match?(/\A[a-z][a-z0-9_$()+-]*\z/) }
        raise ArgumentError, "Invalid CouchDB database name(s): #{invalid.join(', ')}" if invalid.any?
      end
  end

  def compact_database_and_indexes!(database)
    database_url = couchdb_url(database)
    database_info = get_json(database_url)

    compact_database_file!(database, database_url, database_info)
    design_documents(database_url).each do |design_document|
      compact_design_document!(database, database_url, design_document)
    end

    RestClient.post("#{database_url}/_view_cleanup", '{}', json_headers)
    @logger&.info("[CouchDB Compaction] Finished #{database}")
  rescue RestClient::NotFound
    @logger&.warn("[CouchDB Compaction] Skipping missing database #{database}")
  end

  def compact_database_file!(database, database_url, database_info)
    if database_info['compact_running']
      wait_until("database compaction for #{database}") { !get_json(database_url)['compact_running'] }
      database_info = get_json(database_url)
    end

    unless should_compact?(database_info.dig('sizes'))
      @logger&.info("[CouchDB Compaction] Skipping #{database} database file; fragmentation is below threshold")
      return
    end

    @logger&.info("[CouchDB Compaction] Starting database compaction for #{database}")
    RestClient.post("#{database_url}/_compact", '{}', json_headers)
    wait_for_compaction_to_settle("database compaction for #{database}") do
      get_json(database_url)['compact_running']
    end
  end

  def compact_design_document!(database, database_url, design_document)
    info_url = "#{database_url}/_design/#{encode_segment(design_document)}/_info"
    design_info = get_json(info_url)
    sizes = design_info.dig('view_index', 'sizes')

    unless should_compact?(sizes)
      @logger&.debug("[CouchDB Compaction] Skipping #{database}/#{design_document}; fragmentation is below threshold")
      return
    end

    @logger&.info("[CouchDB Compaction] Starting index compaction for #{database}/#{design_document}")
    RestClient.post("#{database_url}/_compact/#{encode_segment(design_document)}", '{}', json_headers)
    wait_for_compaction_to_settle("index compaction for #{database}/#{design_document}") do
      get_json(info_url).dig('view_index', 'compact_running')
    end
  end

  def design_documents(database_url)
    response = get_json("#{database_url}/_design_docs?limit=10000")
    Array(response['rows']).filter_map do |row|
      id = row['id'].to_s
      id.delete_prefix('_design/') if id.start_with?('_design/')
    end
  end

  def should_compact?(sizes)
    file_size = sizes.to_h['file'].to_i
    active_size = sizes.to_h['active'].to_i
    return false if file_size <= 0 || active_size <= 0

    reclaimable = file_size - active_size
    ratio = file_size.to_f / active_size

    reclaimable >= min_reclaimable_bytes && ratio >= min_file_to_active_ratio
  end

  def wait_for_compaction_to_settle(description, &running)
    started = false
    grace_deadline = @clock.call + start_grace_seconds
    deadline = @clock.call + timeout_seconds

    loop do
      is_running = running.call == true
      started ||= is_running
      return true if !is_running && (started || @clock.call >= grace_deadline)

      raise Timeout::Error, "Timed out waiting for #{description}" if @clock.call >= deadline

      @sleeper.call(poll_interval_seconds)
    end
  end

  def wait_until(description)
    deadline = @clock.call + timeout_seconds

    until yield
      raise Timeout::Error, "Timed out waiting for #{description}" if @clock.call >= deadline

      @sleeper.call(poll_interval_seconds)
    end
  end

  def get_json(url)
    JSON.parse(RestClient.get(url, accept: :json).body)
  end

  def encode_segment(value)
    URI.encode_www_form_component(value.to_s)
  end

  def json_headers
    { content_type: :json, accept: :json }
  end

  def poll_interval_seconds
    positive_integer_env('COUCHDB_COMPACTION_POLL_SECONDS', DEFAULT_POLL_INTERVAL_SECONDS)
  end

  def timeout_seconds
    positive_integer_env('COUCHDB_COMPACTION_TIMEOUT_SECONDS', DEFAULT_TIMEOUT_SECONDS)
  end

  def start_grace_seconds
    positive_integer_env('COUCHDB_COMPACTION_START_GRACE_SECONDS', DEFAULT_START_GRACE_SECONDS)
  end

  def min_reclaimable_bytes
    positive_integer_env('COUCHDB_COMPACTION_MIN_RECLAIMABLE_BYTES', DEFAULT_MIN_RECLAIMABLE_BYTES)
  end

  def min_file_to_active_ratio
    value = Float(ENV.fetch('COUCHDB_COMPACTION_MIN_RATIO', DEFAULT_MIN_FILE_TO_ACTIVE_RATIO))
    value.positive? ? value : DEFAULT_MIN_FILE_TO_ACTIVE_RATIO
  rescue ArgumentError, TypeError
    DEFAULT_MIN_FILE_TO_ACTIVE_RATIO
  end

  def positive_integer_env(name, fallback)
    value = Integer(ENV.fetch(name, fallback))
    value.positive? ? value : fallback
  rescue ArgumentError, TypeError
    fallback
  end
end
