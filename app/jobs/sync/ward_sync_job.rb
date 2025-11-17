# app/jobs/sync/ward_sync_job.rb
module Sync
  class WardSyncJob < BaseSyncJob
    
    # Sync all wards to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Location, 'wards', batch_size) do |model_class|
        model_class.where(retired: false, description: "Ward")
      end
    end
    
    private
    
    def prepare_document(ward)
      {
        "type" => "ward",
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
        "neighborhood_cell" => ward.neighborhood_cell,
        "region" => ward.region,
        "subregion" => ward.subregion,
        "township_division" => ward.township_division,
        "parent_location" => ward.parent_location,
        "uuid" => ward.uuid,
        "created_at" => ward.date_created&.iso8601,
        "retired" => ward.retired,
        "synced_at" => Time.current.iso8601
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