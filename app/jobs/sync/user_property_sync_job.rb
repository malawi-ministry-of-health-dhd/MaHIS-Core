# frozen_string_literal: true

module Sync
  class UserPropertySyncJob < BaseSyncJob
    sidekiq_options queue: 'sync_offline_data', retry: 3

    DB_NAME = 'user_properties'

    def perform(batch_size = DEFAULT_BULK_BATCH_SIZE)
      return unless couchdb_configured?

      documents = build_user_documents
      sync_array_to_couchdb(documents, DB_NAME, 'user_property', batch_size)
    end

    private

    # The array helper passes already-built documents straight through.
    def prepare_document(document)
      document
    end

    def generate_document_id(document)
      document['_id']
    end

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
