# frozen_string_literal: true

module Sync
  class SectionSyncJob < BaseSyncJob
    def perform(batch_size = 100, *_unused_args)
      sync_records_to_couchdb(Location, 'sections', batch_size) do |model_class|
        model_class.joins(tag_maps: :location_tag)
                   .where(retired: false, location_tag: { name: 'Section' })
      end
    end

    private

    def prepare_document(section)
      {
        'location_id' => section.location_id,
        'id' => section.location_id,
        'name' => section.name,
        'description' => section.description,
        'address1' => section.address1,
        'address2' => section.address2,
        'city_village' => section.city_village,
        'state_province' => section.state_province,
        'postal_code' => section.postal_code,
        'country' => section.country,
        'latitude' => section.latitude,
        'longitude' => section.longitude,
        'county_district' => section.county_district,
        'address3' => section.address3,
        'address4' => section.address4,
        'address5' => section.address5,
        'address6' => section.address6,
        'parent_location' => section.parent_location,
        'parent_location_id' => section.parent_location,
        'parent_id' => section.parent_location,
        'ward_id' => section.parent_location
      }
    end

    def generate_document_id(section)
      "section_#{section.location_id}"
    end

    def get_record_identifier(record)
      record.location_id
    end
  end
end
