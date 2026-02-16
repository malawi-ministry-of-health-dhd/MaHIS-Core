module Sync
  class FacilitySyncJob < BaseSyncJob
    
    def perform(batch_size = 5000) 
      sync_records_to_couchdb(Location, 'facilities', batch_size) do |model_class|
        model_class.where(retired: false)
                  .where.not(city_village: [nil, ""])
      end
    end
    
    private
    
    def get_required_columns
      [
        :location_id,
        :name,
        :city_village,
        :latitude,
        :longitude
      ]
    end
    
    def prepare_document(facility)
      {
        "dde_activated" => false,
        "location_id" => facility.location_id,
        "name" => facility.name,
        "district" => facility.city_village,
        "latitude" => facility.latitude,
        "longitude" => facility.longitude,
      }
    end
    
    def generate_document_id(facility)
      "facility_#{facility.location_id}"
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::FacilitySyncJob.perform_async          # Uses default 5000 batch size
# Sync::FacilitySyncJob.perform_async(10000)   # Larger batches for many facilities
# Sync::FacilitySyncJob.perform_async(2000)    # Smaller batches if needed
