# app/jobs/sync/concept_set_sync_job.rb
module Sync
  class ConceptSetSyncJob < BaseSyncJob
    
    # Sync all concept sets to CouchDB
    def perform(batch_size = 100)
      concept_sets_data = get_concept_sets_data
      sync_array_to_couchdb(concept_sets_data, 'concept_sets', 'concept_sets', batch_size, 
                           progress_interval: 50, rate_limit_interval: 10)
    end
    
    private
    
    def get_concept_sets_data
      # Set the group_concat_max_len to handle large concatenated strings
      ActiveRecord::Base.connection.execute("SET SESSION group_concat_max_len = 1000000")
      
      concept_sets = ConceptName
        .select("concept_name.name AS concept_set_name,
                 concept_name.concept_id AS concept_set_id, 
                 COALESCE(GROUP_CONCAT(DISTINCT concept_set.concept_id), '') AS member_ids")
        .joins("JOIN concept_set ON concept_name.concept_id = concept_set.concept_set")
        .where(voided: 0)
        .group("concept_name.concept_id")
        .order("concept_name.name")
      
      # Transform the data to match the expected format
      concept_sets.map do |result|
        member_ids = result.member_ids.present? ? result.member_ids.split(",").map(&:to_i) : []
        {
          id: result.concept_set_id,
          concept_set_name: result.concept_set_name,
          member_ids: member_ids
        }
      end
    end
    
    def prepare_document(concept_set_data)
      {
        "type" => "concept_set",
        "concept_set_id" => concept_set_data[:id],
        "concept_set_name" => concept_set_data[:concept_set_name],
        "member_ids" => concept_set_data[:member_ids],
        "member_count" => concept_set_data[:member_ids].length,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(concept_set_data)
      "concept_set_#{concept_set_data[:id]}"
    end
  end
end

# Usage examples:
# Sync::ConceptSetSyncJob.perform_async(50)   # Smaller batches for testing
# Sync::ConceptSetSyncJob.perform_async(100)  # Default batch size
# Sync::ConceptSetSyncJob.perform_async(200)  # Larger batches for faster sync