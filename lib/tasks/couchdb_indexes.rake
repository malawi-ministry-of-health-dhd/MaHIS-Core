# frozen_string_literal: true

namespace :couchdb do
  desc 'Delete design docs for retired patients_records indexes (PatientRecordSearchFields::RETIRED_COUCHDB_INDEXES)'
  task prune_retired_patient_indexes: :environment do
    retired = PatientRecordSearchFields::RETIRED_COUCHDB_INDEXES
    puts "Pruning #{retired.length} retired patients_records index(es): #{retired.join(', ')}"
    abort('CouchDB is not configured') unless CouchdbIndexMaintenance.prune_patient_records!(logger: Rails.logger)
    puts 'Done. Remaining indexes are the ones still in COUCHDB_INDEXES.'
  end
end
