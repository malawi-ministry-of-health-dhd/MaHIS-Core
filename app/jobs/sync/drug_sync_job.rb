module Sync
  class DrugSyncJob < BaseSyncJob
    
    def perform(batch_size = 5000) 
      sync_records_to_couchdb(Drug, 'drugs', batch_size) do |model_class|
        model_class.where(retired: 0)
      end
    end
    
    private
    def get_required_columns
      [
        :drug_id,
        :concept_id,
        :name,
        :combination,
        :dosage_form,
        :dose_strength,
        :maximum_daily_dose,
        :minimum_daily_dose,
        :route,
        :units
      ]
    end
    
    def prepare_document(drug)
      {
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
      }
    end
    
    def generate_document_id(drug)
      "drug_#{drug.drug_id}"
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::DrugSyncJob.perform_async          # Uses default 5000 batch size
# Sync::DrugSyncJob.perform_async(10000)   # Even larger batches for huge datasets
# Sync::DrugSyncJob.perform_async(2000)    # Smaller batches if memory constrained
