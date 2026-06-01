# app/jobs/sync/department_sync_job.rb
module Sync
  class DepartmentSyncJob < BaseSyncJob

    # Sync all departments (Location rows tagged "Department") to CouchDB
    def perform(batch_size = 5000)
      sync_records_to_couchdb(Location, 'departments', batch_size) do |model_class|
        model_class.joins(tag_maps: :location_tag)
                   .where(retired: false, location_tag: { name: 'Department' })
                   .distinct
      end
    end

    private

    def get_required_columns
      %i[
        location_id
        name
        description
        address1
        address2
        city_village
        state_province
        postal_code
        country
        latitude
        longitude
        county_district
        parent_location
        retired
      ]
    end

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
        "neighborhood_cell" => location_attribute(department, :neighborhood_cell),
        "region" => location_attribute(department, :region),
        "subregion" => location_attribute(department, :subregion),
        "township_division" => location_attribute(department, :township_division),
        "parent_location" => department.parent_location,
      }
    end

    def generate_document_id(department)
      "department_#{department.location_id}"
    end

    def get_record_identifier(record)
      record.location_id
    end

    # The base class derives the CouchDB document prefix from the model name
    # (Location -> "location_"), but this job writes docs with a "department_"
    # prefix. Override so the pre-sync count check and cleanup target the
    # correct documents in the `departments` database.
    def get_document_prefix(_model_class)
      'department_'
    end

    def location_attribute(location, attribute)
      return location.public_send(attribute) if location.has_attribute?(attribute)

      nil
    end
  end
end

# Usage examples:
# Sync::DepartmentSyncJob.perform_async          # Default 5000 batch size
# Sync::DepartmentSyncJob.perform_async(2000)    # Smaller batches
