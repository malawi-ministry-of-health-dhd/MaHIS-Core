module Sync
  class DistrictSyncJob < BaseSyncJob
    
    def perform(batch_size = 5000) 
      sync_records_to_couchdb(District, 'districts', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end
    
    private
    def get_required_columns
      [:district_id, :location_id, :name, :parent_location]
    end
    
    def prepare_document(district)
      {
        "location_id" => district.location_id,
        "name" => district.name,
        "parent_location" => district.parent_location,
      }
    end
    
    def generate_document_id(district)
      "district_#{district.location_id}"
    end
  end
end

# Usage - automatically uses bulk sync:
# Sync::DistrictSyncJob.perform_async             # Uses default 5000
# Sync::DistrictSyncJob.perform_async(2000)       # Smaller batches
