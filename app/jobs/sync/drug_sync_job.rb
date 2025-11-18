# app/jobs/sync/drug_sync_job.rb
module Sync
  class DrugSyncJob < BaseSyncJob
    
    # Sync all drugs to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Drug, 'drugs', batch_size) do |model_class|
        model_class.where(retired: 0)
      end
    end
    
    private
    
    def prepare_document(drug)
      {
        "type" => "drug",
        "drug_id" => drug.drug_id,
        "concept_id" => drug.concept_id,
        "name" => drug.name,
        "combination" => drug.combination,
        "dosage_form" => drug.dosage_form,
        "dose_strength" => drug.dose_strength,
        "maximum_daily_dose" => drug.maximum_daily_dose,
        "minimum_daily_dose" => drug.minimum_daily_dose,
        "route" => drug.route,
        "units" => drug.units,
        "creator" => drug.creator,
        "created_at" => drug.date_created&.iso8601,
        "retired" => drug.retired,
        "retired_by" => drug.retired_by,
        "date_retired" => drug.date_retired&.iso8601,
        "retire_reason" => drug.retire_reason,
        "uuid" => drug.uuid,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(drug)
      "drug_#{drug.drug_id}"
    end
  end
end

# Usage examples:
# Sync::DrugSyncJob.perform_async(50)