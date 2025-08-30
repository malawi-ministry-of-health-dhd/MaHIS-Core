# app/jobs/sync/facility_sync_job.rb
module Sync
  class FacilitySyncJob < BaseSyncJob
    
    # Sync all facilities to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Facility, 'facilities', batch_size)
    end
    
    private
    
    def prepare_document(facility)
      {
        "type" => "facility",
        "facility_id" => facility.id,
        "code" => facility.code,
        "name" => facility.name,
        "common" => facility.common,
        "ownership" => facility.ownership,
        "facility_type" => facility.facility_type,
        "status" => facility.status,
        "regulatory_status" => facility.regulatory_status,
        "district" => facility.district,
        "date_opened" => facility.date_opened&.iso8601,
        "latitude" => facility.latitude,
        "longitude" => facility.longitude,
        "created_at" => facility.created_at&.iso8601,
        "updated_at" => facility.updated_at&.iso8601,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(facility)
      "facility_#{facility.id}"
    end
  end
end

# Usage examples:
# Sync::FacilitySyncJob.perform_async(50)  # Smaller batches
# Sync::FacilitySyncJob.perform_async      # Default batch size of 100