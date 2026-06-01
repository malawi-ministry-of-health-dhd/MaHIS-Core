# app/jobs/sync/location_sync_job.rb
module Sync
  class LocationSyncJob < BaseSyncJob

    # Sync all non-retired locations to CouchDB using BULK operations
    def perform(batch_size = 5000)
      sync_records_to_couchdb(Location, 'locations', batch_size) do |model_class|
        model_class.includes(:parent, :location_attributes)
                   .where(retired: false)
      end
    end

    private

    # Keep this aligned with the locations API response payload.
    def get_required_columns
      [
        :location_id,
        :name,
        :description,
        :address1,
        :address2,
        :city_village,
        :state_province,
        :postal_code,
        :country,
        :latitude,
        :longitude,
        :creator,
        :date_created,
        :county_district,
        :address3,
        :address4,
        :address5,
        :address6,
        :retired,
        :retired_by,
        :date_retired,
        :retire_reason,
        :parent_location,
        :uuid,
        :changed_by,
        :date_changed
      ]
    end

    def prepare_document(location)
      location.as_json(
        include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      )
    end

    def generate_document_id(location)
      "location_#{location.location_id}"
    end

    def get_record_identifier(record)
      record.location_id
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::LocationSyncJob.perform_async          # Uses default 5000 batch size
# Sync::LocationSyncJob.perform_async(10000)   # Larger batches if many locations
# Sync::LocationSyncJob.perform_async(2000)    # Smaller batches if needed
