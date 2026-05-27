# app/jobs/sync/department_sync_job.rb
module Sync
  class DepartmentSyncJob < BaseSyncJob

    # Sync all departments to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Location, 'departments', batch_size) do |model_class|
        model_class.joins(tag_maps: :location_tag)
                   .where(retired: false, location_tag: { name: "Department" })
      end
    end

    private

    def prepare_document(department)
      {
        "location_id" => department.location_id,
        "name" => department.name,
        "description" => department.description,
        "address1" => department.address1,
        "address2" => department.address2,
        "city_village" => department.city_village,
        "state_province" => department.state_province,
        "postal_code" => department.postal_code,
        "country" => department.country,
        "latitude" => department.latitude,
        "longitude" => department.longitude,
        "county_district" => department.county_district,
        "address3" => department.address3,
        "address4" => department.address4,
        "address5" => department.address5,
        "address6" => department.address6,
        "parent_location" => department.parent_location,
      }
    end

    def generate_document_id(department)
      "department_#{department.location_id}"
    end

    # Override the record identifier method for departments
    def get_record_identifier(record)
      record.location_id
    end
  end
end

# Usage examples:
# Sync::DepartmentSyncJob.perform_async(50)  # Smaller batches for better performance
# Sync::DepartmentSyncJob.perform_async      # Default batch size of 100
