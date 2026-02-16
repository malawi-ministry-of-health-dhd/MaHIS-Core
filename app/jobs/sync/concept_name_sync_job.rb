module Sync
  class ConceptNameSyncJob < BaseSyncJob
    
    def perform(batch_size = 5000) 
      sync_records_to_couchdb(ConceptName, 'concept_names', batch_size) do |model_class|
        model_class.where(voided: 0)
      end
    end
    
    private
    def get_required_columns
      [:concept_name_id, :concept_id, :name, :concept_name_type]
    end
    
    def prepare_document(concept_name)
      {
        "concept_name_id" => concept_name.concept_name_id,
        "concept_id" => concept_name.concept_id,
        "name" => concept_name.name,
        "concept_name_type" => concept_name.concept_name_type,
        "date_created" => concept_name.date_created&.iso8601,
      }
    end
    
    def generate_document_id(concept_name)
      concept_name.uuid
    end
  end
end

# Usage - automatically uses bulk sync:
# Sync::ConceptNameSyncJob.perform_async          # Uses default 5000
# Sync::ConceptNameSyncJob.perform_async(10000)   # Even larger batches
# Sync::ConceptNameSyncJob.perform_async(1000)    # Smaller batches if needed