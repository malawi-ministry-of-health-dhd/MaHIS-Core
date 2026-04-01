# app/jobs/sync/test_result_indicators_sync_job.rb
module Sync
  class TestResultIndicatorsSyncJob < BaseSyncJob
    # Sync all test result indicators to CouchDB
    def perform(batch_size = 50)
      # Get test result indicators using the per-test indicator lookup
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
        "concept_id" => fetch_value(indicator, :concept_id),
        "name" => fetch_value(indicator, :name),
        "concept_set" => fetch_value(indicator, :concept_set),
        "nlims_code" => fetch_value(indicator, :nlims_code),
        "uuid" => fetch_value(indicator, :uuid)
      }.compact
    end


    def generate_document_id(indicator)
      "test_indicator_#{fetch_value(indicator, :concept_id)}_#{fetch_value(indicator, :concept_set)}"
    end

    def fetch_value(record, key)
      record[key] || record[key.to_s] || record[key.to_sym]
    end
  end
end

# Usage examples:
# Sync::TestResultIndicatorsSyncJob.perform_async     # Default batch size of 50
# Sync::TestResultIndicatorsSyncJob.perform_async(25) # Smaller batches
# Sync::TestResultIndicatorsSyncJob.perform_async(100) # Larger batches
