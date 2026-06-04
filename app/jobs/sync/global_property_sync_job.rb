# frozen_string_literal: true

module Sync
  class GlobalPropertySyncJob < BaseSyncJob
    sidekiq_options queue: 'sync_offline_data', retry: 3

    DB_NAME = 'global_properties'

    def perform(batch_size = DEFAULT_BULK_BATCH_SIZE)
      return unless couchdb_configured?

      documents = GlobalProperty.all.map { |gp| build_document(gp) }
      sync_array_to_couchdb(documents, DB_NAME, 'global_property', batch_size)
    end

    private

    # The array helper passes already-built documents straight through.
    def prepare_document(document)
      document
    end

    def generate_document_id(document)
      document['_id']
    end

    def build_document(gp)
      {
        '_id'            => "global_property_#{gp.uuid}",
        'property'       => gp.property.to_s,
        'property_value' => gp.property_value,
        'description'    => gp.description,
        'location_id'    => gp.location_id,
        'uuid'           => gp.uuid
      }
    end
  end
end

# Usage:
# Sync::GlobalPropertySyncJob.perform_async
