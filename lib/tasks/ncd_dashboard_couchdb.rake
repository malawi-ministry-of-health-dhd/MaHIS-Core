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
  end
end
