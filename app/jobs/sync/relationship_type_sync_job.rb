# app/jobs/sync/relationship_type_sync_job.rb
module Sync
  class RelationshipTypeSyncJob < BaseSyncJob
    
    # Sync all relationship types to CouchDB
    def perform(batch_size = 50) # Small default batch size due to small dataset
      sync_records_to_couchdb(RelationshipType, 'relationship', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end
    
    private
    
    def prepare_document(relationship_type)
      {
        "type" => "relationship_type",
        "relationship_type_id" => relationship_type.relationship_type_id,
        "a_is_to_b" => relationship_type.a_is_to_b,
        "b_is_to_a" => relationship_type.b_is_to_a,
        "preferred" => relationship_type.preferred,
        "weight" => relationship_type.weight,
        "description" => relationship_type.description,
        "creator" => relationship_type.creator,
        "created_at" => relationship_type.date_created&.iso8601,
        "uuid" => relationship_type.uuid,
        "retired" => relationship_type.retired,
        "retired_by" => relationship_type.retired_by,
        "date_retired" => relationship_type.date_retired&.iso8601,
        "retire_reason" => relationship_type.retire_reason,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(relationship_type)
      "relationship_type_#{relationship_type.relationship_type_id}"
    end
  end
end

# Usage examples:
# Sync::RelationshipTypeSyncJob.perform_async(10)  # Small batches for testing
# Sync::RelationshipTypeSyncJob.perform_async(50)  # Default batch size
# Sync::RelationshipTypeSyncJob.perform_async      # Use default batch size