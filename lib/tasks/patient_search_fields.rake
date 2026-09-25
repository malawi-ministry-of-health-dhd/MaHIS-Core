# frozen_string_literal: true

require 'cgi'

namespace :couchdb do
  # Documents are only stamped when they are written, so a field added to
  # PatientRecordSearchFields.normalize! is missing from every document already
  # in the database — and a selector on that field silently matches nothing.
  # Run this once after adding one. Re-running it is safe: normalize! derives
  # every field from the document itself, so a document that is already correct
  # is rewritten unchanged.
  desc 'Restamp the search fields on every patients_records CouchDB document'
  task backfill_patient_search_fields: :environment do
    unless CouchdbPatientService.couchdb_configured?
      puts 'CouchDB is not configured; nothing to backfill.'
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
      url += "&startkey=#{CGI.escape(last_id.to_json)}&skip=1" if last_id.present?

      rows = JSON.parse(RestClient.get(url, accept: :json).body).fetch('rows', [])
      break if rows.empty?

      last_id = rows.last['id']
      docs = rows.filter_map { |row| row['doc'] }.reject { |doc| doc['_id'].to_s.start_with?('_design/') }

      if docs.any?
        docs.each { |doc| PatientRecordSearchFields.normalize!(doc) }
        RestClient.post("#{db_url}/_bulk_docs", { docs: docs }.to_json,
                        { content_type: :json, accept: :json })
        processed += docs.length
        puts "Restamped #{processed} patient documents; last_id=#{last_id}"
      end

      break if rows.length < batch_size
    end

    puts "Finished. Documents processed: #{processed}"
  end
end
