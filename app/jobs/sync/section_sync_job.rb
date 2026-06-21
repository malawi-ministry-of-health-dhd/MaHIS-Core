# app/jobs/sync/section_sync_job.rb
module Sync
  class SectionSyncJob < BaseSyncJob

    # Sync all sections (Location rows tagged "Section") to CouchDB
    def perform(batch_size = 5000)
      sync_records_to_couchdb(Location, 'sections', batch_size) do |model_class|
        section_tag = LocationTag.where('LOWER(name) = ?', 'section').first ||
                      LocationTag.where('name like ?', '%Section%').first

        if section_tag
          model_class.includes(:parent, :location_attributes)
                     .where(retired: false)
                     .joins(:tag_maps)
                     .merge(LocationTagMap.where(location_tag_id: section_tag.location_tag_id))
                     .distinct
                     .order(:name)
        else
          model_class.none
        end
      end
    end

    private

    def prepare_document(section)
      section.as_json(
        include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      )
    end

    def generate_document_id(section)
      "section_#{section.location_id}"
    end

    def get_record_identifier(record)
      record.location_id
    end

    def get_document_prefix(_model_class)
      'section_'
    end

    # Sections are small reference data. Always upsert them instead of relying
    # on count-only checks, which can skip when CouchDB has stale section docs.
    def check_and_clean_couchdb_if_needed_for_model(_model_class, _db_name, _query, _last_updated = nil)
      :continue_sync
    end

  end
end

# Usage examples:
# Sync::SectionSyncJob.perform_async          # Default 5000 batch size
# Sync::SectionSyncJob.perform_async(2000)    # Smaller batches
