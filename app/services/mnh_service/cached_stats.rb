# frozen_string_literal: true

require 'rest-client'
require 'json'

module MnhService
  # Reads precomputed MNH stats from the mnh_stats CouchDB database written by
  # Sync::MnhStatsSyncJob, so the online dashboard can serve a single date or
  # the all-time view from one CouchDB GET instead of recomputing ~17 MySQL
  # aggregates per program. Returns nil (so the caller falls back to the live
  # MnhService::Engine) for date ranges, cache misses, or any error.
  module CachedStats
    DB_NAME = Sync::MnhStatsSyncJob::DB_NAME

    module_function

    def fetch(location_id:, program_id: nil, program_key: nil, date: nil, start_date: nil, end_date: nil)
      # Ranges are not precomputed (only single dates and all-time docs exist).
      return nil if start_date.present? || end_date.present?
      return nil unless CouchdbPatientService.couchdb_configured?

      key = program_key.presence || Sync::MnhStatsSyncJob.program_key_for_program_id(program_id)
      return nil if key.blank?

      loc = resolved_location_id(location_id)
      return nil if loc.blank?

      doc_id = "mnh_stat_#{loc}_#{key}_#{date_key(date)}"
      doc = JSON.parse(RestClient.get(CouchdbPatientService.couchdb_url(DB_NAME, doc_id), accept: :json).body)
      doc['stats']
    rescue RestClient::NotFound
      nil
    rescue StandardError => e
      Rails.logger.warn("[MnhService::CachedStats] falling back to MySQL: #{e.class}: #{e.message}")
      nil
    end

    def resolved_location_id(location_id)
      (location_id.presence || Location.current&.location_id || User.current&.location_id).to_s.strip.presence
    end

    def date_key(date)
      return 'all' if date.blank?

      Date.parse(date.to_s).iso8601
    rescue ArgumentError, TypeError
      'all'
    end
  end
end
