# app/jobs/sync/ward_sync_job.rb
module Sync
  class WardSyncJob < BaseSyncJob
    
    # Sync all wards to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Location, 'wards', batch_size) do |model_class|
        model_class.joins(:tag_maps => :location_tag)
                   .where(retired: false, location_tag: { name: "Ward" })
      end
    end
    
    private
    
    def prepare_document(ward)     
      {
        "location_id" => ward.location_id,
        "name" => ward.name,
        "description" => ward.description,
        "address1" => ward.address1,
        "address2" => ward.address2,
        "city_village" => ward.city_village,
        "state_province" => ward.state_province,
        "postal_code" => ward.postal_code,
        "country" => ward.country,
        "latitude" => ward.latitude,
        "longitude" => ward.longitude,
        "county_district" => ward.county_district,
        "address3" => ward.address3,
        "address4" => ward.address4,
        "address5" => ward.address5,
        "address6" => ward.address6,
        "parent_location" => ward.parent_location,
      }
    end
    
    def generate_document_id(ward)
      "ward_#{ward.location_id}"
    end
    
    # Override the record identifier method for wards
    def get_record_identifier(record)
      record.location_id
    end
  end
end

# Usage examples:
# Sync::WardSyncJob.perform_async(50)  # Smaller batches for better performance
# Sync::WardSyncJob.perform_async     # Default batch size of 100