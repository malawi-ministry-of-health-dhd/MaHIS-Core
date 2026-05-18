# frozen_string_literal: true

module Sync
  class ArvDrugSyncJob < BaseSyncJob
    DB_NAME = 'arv_drugs'

    def perform(batch_size = DEFAULT_BULK_BATCH_SIZE)
      sync_records_to_couchdb(Drug, DB_NAME, batch_size) do |model_class|
        model_class.arv_drugs
      end
    end

    private

    def get_required_columns
      %i[drug_id concept_id name combination dosage_form dose_strength
         maximum_daily_dose minimum_daily_dose route units]
    end

    def prepare_document(drug)
      {
        'drug_id'           => drug.drug_id,
        'concept_id'        => drug.concept_id,
        'name'              => drug.name,
        'combination'       => drug.combination,
        'dosage_form'       => drug.dosage_form,
        'dose_strength'     => drug.dose_strength,
        'maximum_daily_dose' => drug.maximum_daily_dose,
        'minimum_daily_dose' => drug.minimum_daily_dose,
        'route'             => drug.route,
        'units'             => drug.units
      }
    end

    def generate_document_id(drug)
      "arv_drug_#{drug.drug_id}"
    end
  end
end

# Usage:
# Sync::ArvDrugSyncJob.perform_async
# rails "sync:run[ArvDrugSyncJob]"
