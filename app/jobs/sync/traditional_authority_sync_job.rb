# app/jobs/sync/traditional_authority_sync_job.rb
module Sync
  class TraditionalAuthoritySyncJob < BaseSyncJob
    
    def perform(batch_size = 5000) # Increased from 100 for bulk ops
      sync_records_to_couchdb(TraditionalAuthority, 'traditional_authorities', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end

    private
    
    def get_required_columns
      [
        :location_id,
        :name,
        :parent_location
      ]
    end

    def prepare_document(traditional_authority)
      {
        "location_id" => traditional_authority.location_id,
        "name" => traditional_authority.name,
        "parent_location" => traditional_authority.parent_location
      }
    end

    def generate_document_id(traditional_authority)
      "traditional_authority_#{traditional_authority.location_id}"
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::TraditionalAuthoritySyncJob.perform_async          # Uses default 5000 batch size
# Sync::TraditionalAuthoritySyncJob.perform_async(10000)   # Larger batches if many records
# Sync::TraditionalAuthoritySyncJob.perform_async(2000)    # Smaller batches if needed