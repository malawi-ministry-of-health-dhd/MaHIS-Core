# frozen_string_literal: true

module Sync
  class UserPropertySyncJob < BaseSyncJob
    sidekiq_options queue: 'sync_offline_data', retry: 3

    DB_NAME = 'user_properties'

    def perform(_batch_size = nil)
      return unless couchdb_configured?

      ensure_database_exists(DB_NAME)

      rows = build_user_documents

      return Sidekiq.logger.info('UserPropertySyncJob: no records to sync') if rows.empty?

      result = bulk_sync_to_couchdb(rows, DB_NAME)

      if result[:errors].any?
        Sidekiq.logger.error("UserPropertySyncJob: #{result[:errors].length} errors")
        result[:errors].first(5).each { |e| Sidekiq.logger.error("  #{e}") }
      else
        Sidekiq.logger.info("UserPropertySyncJob: synced #{rows.size} user documents")
      end
    end

    private

    def build_user_documents
      UserProperty.joins(:user)
                  .where(users: { retired: 0 }, property: 'activities')
                  .group_by(&:user_id)
                  .map do |user_id, props|
                    user = props.first.user
                    {
                      '_id'         => "user_property_#{user_id}",
                      'user_id'     => user_id,
                      'username'    => user&.username,
                      'location_id' => user&.location_id,
                      'properties'  => props.each_with_object({}) do |up, h|
                                         h[up.property] = up.property_value
                                       end
                    }
                  end
    end
  end
end

# Usage:
# Sync::UserPropertySyncJob.perform_async
