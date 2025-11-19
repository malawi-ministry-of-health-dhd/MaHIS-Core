# app/jobs/sync/traditional_authority_sync_job.rb
module Sync
  class TraditionalAuthoritySyncJob < BaseSyncJob
    # Sync all traditional authorities to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(TraditionalAuthority, 'traditional_authorities', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end

    private

    def prepare_document(traditional_authority)
      {
        "type" => "traditional_authority",
        "traditional_authority_id" => traditional_authority.traditional_authority_id,
        "name" => traditional_authority.name,
        "district_id" => traditional_authority.district_id,
        "creator" => traditional_authority.creator,
        "retired" => traditional_authority.retired,
        "retired_by" => traditional_authority.retired_by,
        "retire_reason" => traditional_authority.retire_reason,
        "date_created" => traditional_authority.date_created&.iso8601,
        "date_retired" => traditional_authority.date_retired&.iso8601,
        "synced_at" => Time.current.iso8601
      }
    end

    def generate_document_id(traditional_authority)
      "traditional_authority_#{traditional_authority.traditional_authority_id}"
    end
  end
end

# Usage examples:
# Sync::TraditionalAuthoritySyncJob.perform_async(50)  # Custom batch size
# Sync::TraditionalAuthoritySyncJob.perform_async     # Default batch size of 100