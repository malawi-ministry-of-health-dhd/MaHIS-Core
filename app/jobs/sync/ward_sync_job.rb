# app/jobs/sync/ward_sync_job.rb
module Sync
  class WardSyncJob < BaseSyncJob
    
    # Sync all wards to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Location, 'wards', batch_size) do |model_class|
        ward_tag = LocationTag.where('LOWER(name) = ?', 'ward').first ||
                   LocationTag.where('name like ?', '%Ward%').first

        if ward_tag
          model_class.includes(:parent, :location_attributes)
                     .where(retired: false)
                     .joins(:tag_maps)
                     .merge(LocationTagMap.where(location_tag_id: ward_tag.location_tag_id))
                     .distinct
                     .order(:name)
        else
          model_class.none
        end
      end
    end
    
    private
    
    def prepare_document(ward)
      ward.as_json(
        include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      )
    end
    
    def generate_document_id(ward)
      "ward_#{ward.location_id}"
    end
    
    # Override the record identifier method for wards
    def get_record_identifier(record)
      record.location_id
    end

    def get_document_prefix(_model_class)
      'ward_'
    end

    # Wards are small reference data. Always upsert them instead of relying on
    # count-only checks, which can skip when CouchDB has stale ward documents.
    def check_and_clean_couchdb_if_needed_for_model(_model_class, _db_name, _query)
      :continue_sync
    end
  end
end

# Usage examples:
# Sync::WardSyncJob.perform_async(50)  # Smaller batches for better performance
# Sync::WardSyncJob.perform_async     # Default batch size of 100
