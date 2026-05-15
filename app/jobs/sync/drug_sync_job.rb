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
        :units,
        :concept_set_id
      ]
    end
    
    def prepare_document(drug)
      concept_set_ids = get_concept_set_ids(drug)
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
        "concept_set_id" => concept_set_ids.first,    # For backward compatibility
        "concept_set_ids" => concept_set_ids,         # Complete list of all concept sets
      }
    end
    
    def generate_document_id(drug)
      "drug_#{drug.drug_id}"
    end

    def get_concept_set_id(drug)
      concept_set = ConceptSet.find_by(concept_id: drug.concept_id)
      return nil unless concept_set
      concept_set.concept_set
    end

    def get_concept_set_ids(drug)
      ConceptSet.where(concept_id: drug.concept_id)
                .pluck(:concept_set)
                .uniq
                .compact
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::DrugSyncJob.perform_async          # Uses default 5000 batch size
# Sync::DrugSyncJob.perform_async(10000)   # Even larger batches for huge datasets
# Sync::DrugSyncJob.perform_async(2000)    # Smaller batches if memory constrained
