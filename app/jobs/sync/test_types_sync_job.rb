# app/jobs/sync/test_types_sync_job.rb
module Sync
  class TestTypesSyncJob < BaseSyncJob
    
    # Sync all test types to CouchDB
    def perform(batch_size = 50)
      # Get test types using the Lab service
      test_types = Lab::ConceptsService.test_types
      
      # Use the generic array sync method with custom intervals
      sync_array_to_couchdb(
        test_types, 
        'test_types', 
        'test type', 
        batch_size, 
        progress_interval: 25, 
        rate_limit_interval: 5
      )
    end
    
    private
    
    def prepare_document(test_type)
      {
        "concept_id" => test_type["concept_id"],
        "name" => test_type["name"],
        "nlims_code" => test_type["nlims_code"],
      }
    end
    
    def generate_document_id(test_type)
      "test_type_#{test_type["nlims_code"]}"
    end
    
    # Override the record identifier method for test types
    def get_record_identifier(record)
      record.concept_id
    end
  end
end

# Usage examples:
# Sync::TestTypesSyncJob.perform_async     # Default batch size of 50
# Sync::TestTypesSyncJob.perform_async(25) # Smaller batches
# Sync::TestTypesSyncJob.perform_async(10) # Very small batches for careful processing