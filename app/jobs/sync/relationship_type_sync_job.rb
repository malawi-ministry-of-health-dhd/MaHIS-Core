module Sync
  class RelationshipTypeSyncJob < BaseSyncJob
    def perform(batch_size = 2000) 
      sync_records_to_couchdb(RelationshipType, 'relationship', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end
    
    private
    
    def get_required_columns
      [
        :relationship_type_id,
        :a_is_to_b,
        :b_is_to_a,
        :description
      ]
    end
    
    def prepare_document(relationship_type)
      {
        "relationship_type_id" => relationship_type.relationship_type_id,
        "a_is_to_b" => relationship_type.a_is_to_b,
        "b_is_to_a" => relationship_type.b_is_to_a,
        "description" => relationship_type.description,
      }
    end
    
    def generate_document_id(relationship_type)
      "relationship_type_#{relationship_type.relationship_type_id}"
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::RelationshipTypeSyncJob.perform_async          # Uses default 1000 batch size
# Sync::RelationshipTypeSyncJob.perform_async(500)     # Smaller batches if preferred
# Sync::RelationshipTypeSyncJob.perform_async(2000)    # Larger batches
