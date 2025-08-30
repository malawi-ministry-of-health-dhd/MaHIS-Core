# app/jobs/sync/village_sync_job.rb
module Sync
  class VillageSyncJob < BaseSyncJob
    
    # Sync all villages to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Village, 'villages', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end
    
    private
    
    def prepare_document(village)
      {
        "type" => "village",
        "village_id" => village.village_id,
        "name" => village.name,
        "traditional_authority_id" => village.traditional_authority_id,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(village)
      "village_#{village.id}"
    end
  end
end

# Usage examples:
# Sync::VillageSyncJob.perform_async(50)