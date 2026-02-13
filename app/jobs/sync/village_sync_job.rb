# app/jobs/sync/village_sync_job.rb
module Sync
  class VillageSyncJob < BaseSyncJob
    
    # Sync all villages to CouchDB using BULK operations
    def perform(batch_size = 5000) # Increased from 100 for bulk ops
      sync_records_to_couchdb(Village, 'villages', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end
    
    private
    
    # Optional: Specify which columns to select for better performance
    def get_required_columns
      [
        :location_id,
        :name,
        :parent_location
      ]
    end
    
    def prepare_document(village)
      {
        "location_id" => village.location_id,
        "name" => village.name,
        "parent_location" => village.parent_location,
      }
    end
    
    def generate_document_id(village)
      "village_#{village.location_id}"
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::VillageSyncJob.perform_async          # Uses default 5000 batch size
# Sync::VillageSyncJob.perform_async(10000)   # Larger batches if many villages
# Sync::VillageSyncJob.perform_async(2000)    # Smaller batches if needed