# app/jobs/sync/test_result_indicators_sync_job.rb
module Sync
  class TestResultIndicatorsSyncJob < BaseSyncJob
    # Sync all test result indicators to CouchDB
    def perform(batch_size = 50)
      # Get test result indicators using the LabTestService
      test_indicators = LabTestService.all_test_result_indicators
      
      sync_array_to_couchdb(
        test_indicators, 
        'test_result_indicators', 
        'test_result_indicators', 
        batch_size,
        progress_interval: 25,
        rate_limit_interval: 5
      )
    end

    private

    def prepare_document(indicator)
      {
        "concept_id" => indicator[:concept_id],
        "name" => indicator[:name],
        "concept_set" => indicator[:concept_set],
      }
    end


    def generate_document_id(indicator)
      "test_indicator_#{indicator[:concept_id]}_#{indicator[:concept_set]}"
    end
  end
end

# Usage examples:
# Sync::TestResultIndicatorsSyncJob.perform_async     # Default batch size of 50
# Sync::TestResultIndicatorsSyncJob.perform_async(25) # Smaller batches
# Sync::TestResultIndicatorsSyncJob.perform_async(100) # Larger batches