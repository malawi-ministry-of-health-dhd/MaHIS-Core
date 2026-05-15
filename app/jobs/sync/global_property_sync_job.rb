# frozen_string_literal: true

module Sync
  class GlobalPropertySyncJob < BaseSyncJob
    sidekiq_options queue: 'sync_offline_data', retry: 3

    DB_NAME = 'global_properties'

    def perform(_batch_size = nil)
      return unless couchdb_configured?

      ensure_database_exists(DB_NAME)

      rows = GlobalProperty.all.map { |gp| prepare_document(gp) }

      return Sidekiq.logger.info('GlobalPropertySyncJob: no records to sync') if rows.empty?

      result = bulk_sync_to_couchdb(rows, DB_NAME)

      if result[:errors].any?
        Sidekiq.logger.error("GlobalPropertySyncJob: #{result[:errors].length} errors")
        result[:errors].first(5).each { |e| Sidekiq.logger.error("  #{e}") }
      else
        Sidekiq.logger.info("GlobalPropertySyncJob: synced #{rows.size} global properties")
      end
    end

    private

    def prepare_document(gp)
      {
        '_id'            => generate_document_id(gp),
        'property'       => gp.property.to_s,
        'property_value' => gp.property_value,
        'description'    => gp.description,
        'location_id'    => gp.location_id,
        'uuid'           => gp.uuid
      }
    end

    def generate_document_id(gp)
      "global_property_#{gp.uuid}"
    end
  end
end

# Usage:
# Sync::GlobalPropertySyncJob.perform_async
