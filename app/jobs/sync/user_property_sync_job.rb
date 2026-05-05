# frozen_string_literal: true

module Sync
  class UserPropertySyncJob < BaseSyncJob
    sidekiq_options queue: 'sync_offline_data', retry: 3

    DB_NAME = 'user_properties'

    def perform(_batch_size = nil)
      return unless couchdb_configured?

      ensure_database_exists(DB_NAME)

      rows = UserProperty.joins(:user)
                         .where(users: { retired: 0 })
                         .map { |up| prepare_document(up) }

      return Sidekiq.logger.info('UserPropertySyncJob: no records to sync') if rows.empty?

      result = bulk_sync_to_couchdb(rows, DB_NAME)

      if result[:errors].any?
        Sidekiq.logger.error("UserPropertySyncJob: #{result[:errors].length} errors")
        result[:errors].first(5).each { |e| Sidekiq.logger.error("  #{e}") }
      else
        Sidekiq.logger.info("UserPropertySyncJob: synced #{rows.size} user properties")
      end
    end

    private

    def prepare_document(up)
      {
        '_id'            => generate_document_id(up),
        'user_id'        => up.user_id,
        'username'       => up.user&.username,
        'location_id'    => up.user&.location_id,
        'property'       => up.property,
        'property_value' => up.property_value
      }
    end

    def generate_document_id(up)
      slug = up.property.to_s.gsub(/[^a-z0-9_\-]/i, '_')
      "user_property_#{up.user_id}_#{slug}"
    end
  end
end

# Usage:
# Sync::UserPropertySyncJob.perform_async
