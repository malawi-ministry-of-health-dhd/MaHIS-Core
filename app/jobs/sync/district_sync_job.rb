# app/jobs/sync/district_sync_job.rb
module Sync
  class DistrictSyncJob < BaseSyncJob
    
    # Sync all districts to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(District, 'districts', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end
    
    private
    
    def prepare_document(district)
      {
        "type" => "district",
        "location_id" => district.location_id,
        "name" => district.name,
        "parent_location" => district.parent_location,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(district)
      "district_#{district.district_id}"
    end
  end
end

# Usage examples:
# Sync::DistrictSyncJob.perform_async      # Default batch size of 100
# Sync::DistrictSyncJob.perform_async(50)  # Smaller batches if needed
# Sync::DistrictSyncJob.perform_async(25)  # Even smaller batches