# frozen_string_literal: true

require 'cgi'

namespace :ncd do
  namespace :couchdb do
    desc 'Backfill NCD dashboard summary fields on patients_records CouchDB documents'
    task backfill_dashboard_fields: :environment do
      unless CouchdbPatientService.couchdb_configured?
        puts 'CouchDB is not configured; skipping NCD dashboard backfill.'
        next
      end

      db_name = CouchdbPatientService::PATIENTS_DB
      db_url = CouchdbPatientService.couchdb_url(db_name)
      batch_size = ENV.fetch('BATCH_SIZE', '500').to_i
      processed = 0
      last_id = nil

      CouchdbPatientService.ensure_db_exists(db_name)
      PatientRecordSearchFields.ensure_couchdb_indexes!(db_url, logger: Rails.logger, force: true)

      loop do
        url = "#{db_url}/_all_docs?include_docs=true&limit=#{batch_size}"
        if last_id.present?
          url += "&startkey=#{CGI.escape(last_id.to_json)}&skip=1"
        end

        response = RestClient.get(url, accept: :json)
        rows = JSON.parse(response.body).fetch('rows', [])
        break if rows.empty?

        docs = rows.filter_map { |row| row['doc'] }.reject { |doc| doc['_id'].to_s.start_with?('_design/') }
        if docs.empty?
          last_id = rows.last['id']
          break if rows.length < batch_size

          next
        end
        docs.each { |doc| PatientRecordSearchFields.normalize!(doc) }

        RestClient.post(
          "#{db_url}/_bulk_docs",
          { docs: docs }.to_json,
          { content_type: :json, accept: :json }
        )

        processed += docs.length
        last_id = rows.last['id']
        puts "Backfilled #{processed} patient documents; last_id=#{last_id}"
        break if docs.length < batch_size
      end

      puts "Finished NCD dashboard CouchDB backfill. Documents processed: #{processed}"
    end

    desc 'Backfill the ncd_patient_index CouchDB database from patients_records (NCD patients only)'
    task backfill_ncd_patients: :environment do
      unless CouchdbPatientService.couchdb_configured?
        puts 'CouchDB is not configured; skipping NCD patient index backfill.'
        next
      end

      source_db_url = CouchdbPatientService.couchdb_url(CouchdbPatientService::PATIENTS_DB)
      batch_size = ENV.fetch('BATCH_SIZE', '500').to_i
      scanned = 0
      written = 0
      last_id = nil

      CouchdbPatientService.ensure_db_exists(CouchdbPatientService::PATIENTS_DB)
      NcdService::NcdPatientIndex.ensure!

      loop do
        url = "#{source_db_url}/_all_docs?include_docs=true&limit=#{batch_size}"
        if last_id.present?
          url += "&startkey=#{CGI.escape(last_id.to_json)}&skip=1"
        end

        response = RestClient.get(url, accept: :json)
        rows = JSON.parse(response.body).fetch('rows', [])
        break if rows.empty?

        docs = rows.filter_map { |row| row['doc'] }.reject { |doc| doc['_id'].to_s.start_with?('_design/') }
        scanned += docs.length

        # ncd_projection returns nil for non-NCD records, so upsert_records both
        # filters and writes only NCD patients into the dedicated index DB.
        written += NcdService::NcdPatientIndex.upsert_records(docs)

        last_id = rows.last['id']
        puts "Scanned #{scanned} documents; indexed #{written} NCD patients; last_id=#{last_id}"
        break if rows.length < batch_size
      end

      puts "Finished NCD patient index backfill. Scanned: #{scanned}, NCD patients indexed: #{written}"
    end

    desc 'Drop the legacy NCD indexes and stats view left on patients_records (now on ncd_patient_index)'
    task cleanup_legacy_patient_records_ncd: :environment do
      unless CouchdbPatientService.couchdb_configured?
        puts 'CouchDB is not configured; skipping legacy NCD cleanup.'
        next
      end

      db_url = CouchdbPatientService.couchdb_url(CouchdbPatientService::PATIENTS_DB)
      legacy_ddocs = %w[
        _design/idx_ncd_location_active
        _design/idx_ncd_location_pending_id
        _design/idx_ncd_location_pending_dispensation
        _design/idx_ncd_location_complications
        _design/idx_ncd_location_last_dispensation
        _design/ncd_dashboard_stats
      ]

      legacy_ddocs.each do |ddoc|
        doc_url = "#{db_url}/#{ddoc}"
        rev = JSON.parse(RestClient.get(doc_url, accept: :json).body)['_rev']
        RestClient.delete("#{doc_url}?rev=#{rev}")
        puts "Deleted #{ddoc}"
      rescue RestClient::NotFound
        puts "Skipped #{ddoc} (not present)"
      rescue StandardError => e
        puts "Failed to delete #{ddoc}: #{e.class}: #{e.message}"
      end

      puts 'Finished legacy NCD cleanup on patients_records.'
    end
  end
end
