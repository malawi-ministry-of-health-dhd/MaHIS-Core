# frozen_string_literal: true

module Sync
  class MnhStatsSyncJob < BaseSyncJob
    sidekiq_options queue: 'sync_offline_data',
                    retry: 3,
                    lock: :until_and_while_executing,
                    lock_ttl: 12.hours.to_i,
                    lock_timeout: 0,
                    on_conflict: { client: :log, server: :reject }

    DB_NAME = 'mnh_stats'
    PROGRAMS = {
      'anc' => ['ANC PROGRAM'],
      'labour' => ['LABOUR PROGRAM', 'LABOUR AND DELIVERY PROGRAM'],
      'pnc' => ['PNC PROGRAM', 'POSTNATAL CARE PROGRAM']
    }.freeze

    # Cache the DDE-activated facilities briefly so callbacks and a fan-out burst
    # do not query CouchDB once per observation/facility.
    FACILITIES_CACHE_KEY = 'mnh_stats:dde_activated_location_ids'

    def self.enqueue_for_encounter(encounter)
      return if encounter.blank?

      program_key = program_key_for_program_id(encounter.program_id)
      return if program_key.blank?

      location_id = encounter.location_id.presence || User.current&.location_id
      return if location_id.blank?

      enqueue_date_refresh(location_id, program_key, encounter.encounter_datetime)
    end

    def self.enqueue_for_patient_program(patient_program)
      return if patient_program.blank?

      program_key = program_key_for_program_id(patient_program.program_id)
      return if program_key.blank?

      location_id = patient_program.location_id.presence || User.current&.location_id
      return if location_id.blank?

      enqueue_date_refresh(location_id, program_key, patient_program.date_enrolled)
    end

    def self.enqueue_for_patient_record(record)
      return if record.blank?

      program_keys = patient_record_program_keys(record)
      return if program_keys.empty?

      location_id = record_value(record, :location_id).presence || User.current&.location_id
      return if location_id.blank?

      date = patient_record_date(record)
      program_keys.each do |program_key|
        enqueue_date_refresh(location_id, program_key, date)
      end
    end

    def self.enqueue_date_refresh(location_id, program_key, date)
      normalized_date = normalize_refresh_date(date)
      return if normalized_date.blank?
      return unless dde_activated_location?(location_id)

      perform_async(normalized_date, DEFAULT_BULK_BATCH_SIZE, location_id.to_s, program_key)
    end

    def self.dde_activated_location?(location_id)
      new.dde_activated_location?(location_id)
    end

    def self.normalize_refresh_date(date)
      return if date.blank?

      date.respond_to?(:to_date) ? date.to_date.iso8601 : Date.parse(date.to_s).iso8601
    rescue ArgumentError, TypeError
      nil
    end

    def self.program_key_for_program_id(program_id)
      return if program_id.blank?

      program = Program.unscoped.select(:program_id, :name).find_by(program_id: program_id)
      program_key_for_name(program&.name)
    end

    def self.program_key_for_name(program_name)
      normalized_name = program_name.to_s.upcase.strip
      PROGRAMS.find { |_key, names| names.include?(normalized_name) }&.first
    end

    def self.patient_record_program_keys(record)
      program_ids = [record_value(record, :program_id)]
      program_ids.concat(
        Array(record_value(record, :activePrograms)).filter_map { |program| record_value(program, :program_id) }
      )

      program_ids.compact_blank.map { |program_id| program_key_for_program_id(program_id) }.compact.uniq
    end

    def self.patient_record_date(record)
      date = record_value(record, :encounter_datetime)
      date = record_value(record, :date_enrolled) if date.blank?
      return if date.blank?

      date.respond_to?(:to_date) ? date.to_date.iso8601 : Date.parse(date.to_s).iso8601
    rescue ArgumentError, TypeError
      nil
    end

    def self.record_value(container, key)
      return nil if container.is_a?(String) || container.is_a?(Numeric)
      return nil unless container.respond_to?(:[])

      container[key] || container[key.to_s]
    rescue TypeError
      nil
    end

    def perform(date = nil, batch_size = DEFAULT_BULK_BATCH_SIZE, location_id = nil, program_key = nil, changed_only = false)
      return unless couchdb_configured?

      # No specific facility => act as a dispatcher: fan out one job per
      # facility so Sidekiq workers process them in parallel instead of
      # grinding through every location in a single serial job.
      return dispatch(date, batch_size, program_key, changed_only) if location_id.blank?

      unless dde_activated_location?(location_id)
        return Sidekiq.logger.info(
          "MnhStatsSyncJob: location #{location_id} is not DDE activated; skipping MNH stats"
        )
      end

      normalized_date = normalize_date(date)
      rows = build_stats_rows(normalized_date, location_id, program_key)

      SyncProgress.start(DB_NAME, rows.length)

      if rows.empty?
        SyncProgress.finish(DB_NAME)
        return Sidekiq.logger.info('MnhStatsSyncJob: no MNH stats to sync')
      end

      ensure_database_exists(DB_NAME)

      result = sync_rows(rows, batch_size)
      log_result(result, rows.length)

      if result[:errors].any?
        SyncProgress.fail(DB_NAME, "#{result[:errors].length} errors")
        raise "MNH stats sync failed with #{result[:errors].length} errors"
      end

      SyncProgress.finish(DB_NAME)
    end

    def dde_activated_location?(location_id)
      return false if location_id.blank?

      dde_activated_location_ids.include?(location_id.to_s)
    end

    private

    # Enqueue one per-location job for each facility that needs refreshing.
    # changed_only restricts the fan-out to facilities with recent MNH activity.
    def dispatch(date, batch_size, program_key, changed_only)
      location_ids = target_location_ids(changed_only)

      if location_ids.empty?
        return Sidekiq.logger.info(
          "MnhStatsSyncJob: no #{changed_only ? 'changed ' : ''}facilities to refresh"
        )
      end

      location_ids.each do |loc_id|
        self.class.perform_async(date, batch_size, loc_id.to_s, program_key)
      end

      Sidekiq.logger.info(
        "MnhStatsSyncJob: dispatched #{location_ids.size} per-location jobs (changed_only=#{changed_only})"
      )
    end

    # Always every DDE-activated facility. changed_only is accepted for
    # signature/cron stability but intentionally ignored.
    def target_location_ids(_changed_only = false)
      dde_activated_location_ids
    end

    def build_stats_rows(date, location_id, program_key)
      programs = mnh_programs(program_key)
      return [] if programs.empty?

      locations(location_id).flat_map do |location|
        programs.filter_map do |program_key, program|
          stats_row_for(location, program_key, program, date)
        end
      end
    end

    def stats_row_for(location, program_key, program, date)
      stats = MnhService::Engine.new.stats(program.program_id, date, location_id: location.location_id)
      prepare_document(location, program_key, program, stats, date)
    rescue StandardError => e
      Sidekiq.logger.error(
        "MnhStatsSyncJob: failed #{program_key} stats for location #{location.location_id}: #{e.class}: #{e.message}"
      )
      nil
    end

    def prepare_document(location, program_key, program, stats, date)
      {
        '_id' => generate_document_id(location.location_id, program_key, date),
        'type' => 'mnh_stat',
        'location_id' => location.location_id.to_s,
        'location_name' => location.name,
        'program_id' => program.program_id,
        'program_name' => program.name,
        'program_key' => program_key,
        'date' => date&.iso8601,
        'stats' => stats.deep_stringify_keys,
        'synced_at' => Time.current.iso8601
      }
    end

    def sync_rows(rows, batch_size)
      errors = []
      processed = 0
      rows.each_slice(normalize_batch_size(batch_size)) do |batch|
        result = bulk_sync_to_couchdb(batch, DB_NAME)
        errors.concat(result[:errors]) if result[:errors].any?
        processed += batch.size
        SyncProgress.set(DB_NAME, processed)
      end

      { success: errors.empty?, errors: errors }
    end

    def generate_document_id(location_id, program_key, date)
      date_key = date&.iso8601 || 'all'
      "mnh_stat_#{location_id}_#{program_key}_#{date_key}"
    end

    def mnh_programs(program_key = nil)
      program_definitions = program_key.present? ? PROGRAMS.slice(program_key) : PROGRAMS

      program_definitions.each_with_object({}) do |(key, names), hash|
        program = Program.unscoped.where(name: names).order(:program_id).first
        if program
          hash[key] = program
        else
          Sidekiq.logger.warn("MnhStatsSyncJob: no #{key} program found using names #{names.join(', ')}")
        end
      end
    end

    def locations(location_id = nil)
      facility_ids = dde_activated_location_ids
      if facility_ids.empty?
        Sidekiq.logger.info('MnhStatsSyncJob: no DDE-activated facilities found; skipping MNH stats')
        return Location.none
      end

      scope = Location.unscoped
                      .where(retired: [0, false])
                      .where(location_id: facility_ids)
                      .select(:location_id, :name)
                      .order(:location_id)
      location_id.present? ? scope.where(location_id: location_id) : scope
    end

    def dde_activated_location_ids
      return @dde_activated_location_ids if defined?(@dde_activated_location_ids)
      return @dde_activated_location_ids = [] unless couchdb_configured?

      @dde_activated_location_ids =
        Rails.cache.fetch(FACILITIES_CACHE_KEY, expires_in: 10.minutes) do
          fetch_dde_activated_location_ids
        end
    end

    def fetch_dde_activated_location_ids
      db_url = couchdb_url('facilities')
      selector = {}
      ids = []
      bookmark = nil

      loop do
        query = {
          selector: selector,
          fields: %w[_id location_id dde_activated],
          limit: 1000
        }
        query[:bookmark] = bookmark if bookmark

        response = RestClient.post("#{db_url}/_find", query.to_json, content_type: :json, accept: :json)
        body = JSON.parse(response.body)
        docs = body['docs'] || []
        ids.concat(
          docs.filter_map do |doc|
            next unless dde_activated?(doc)

            facility_location_id(doc)
          end
        )
        bookmark = body['bookmark']
        break if docs.size < 1000
      end

      ids.compact.map(&:to_s).reject(&:blank?).uniq
    rescue RestClient::NotFound
      Sidekiq.logger.warn('MnhStatsSyncJob: facilities DB not found; no DDE-activated facilities to refresh')
      []
    rescue StandardError => e
      Sidekiq.logger.error("MnhStatsSyncJob: failed to load DDE-activated facilities: #{e.class}: #{e.message}")
      []
    end

    def facility_location_id(doc)
      doc['location_id'].presence || doc['_id'].to_s[/\Afacility_(.+)\z/, 1]
    end

    def dde_activated?(doc)
      value = doc['dde_activated']
      value == true || value.to_s.strip.casecmp('true').zero?
    end

    def normalize_date(date)
      return nil if date.blank?

      date.respond_to?(:to_date) ? date.to_date : Date.parse(date.to_s)
    end

    def normalize_batch_size(batch_size)
      size = batch_size.to_i
      size.positive? ? size : DEFAULT_BULK_BATCH_SIZE
    end

    def log_result(result, row_count)
      if result[:errors].any?
        Sidekiq.logger.error("MnhStatsSyncJob: #{result[:errors].length} errors while syncing #{row_count} docs")
        result[:errors].first(5).each { |error| Sidekiq.logger.error("  #{error}") }
      else
        Sidekiq.logger.info("MnhStatsSyncJob: synced #{row_count} MNH stats docs")
      end
    end
  end
end

# Usage:
# Sync::MnhStatsSyncJob.perform_async                                 # dispatch: full rebuild, every DDE-activated facility
# Sync::MnhStatsSyncJob.perform_async(nil, 5000, nil, nil, true)      # dispatch: DDE-activated facilities
# Sync::MnhStatsSyncJob.perform_async(Date.current.to_s)              # dispatch: date-scoped full rebuild
# Sync::MnhStatsSyncJob.perform_async(nil, 5000, '42')                # compute location 42 only when DDE activated
