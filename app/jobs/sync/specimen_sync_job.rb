# app/jobs/sync/specimen_sync_job.rb
module Sync
  class SpecimenSyncJob < BaseSyncJob
    # Sync all specimen types to CouchDB
    def perform(batch_size = 50)
      # Get specimen types using the Lab service
      specimen_types = Lab::ConceptsService.specimen_types()
      
      sync_array_to_couchdb(
        specimen_types, 
        'specimens', 
        'specimens', 
        batch_size,
        progress_interval: 25,
        rate_limit_interval: 5
      )
    end

    private

    def prepare_document(specimen)
      {
        "type" => "specimen",
        "concept_id" => specimen.concept_id,
        "name" => specimen.name,
        "concept_set_id" => specimen.concept_set_id,
        "synced_at" => Time.current.iso8601
      }
    end

    def generate_document_id(specimen)
      "specimen_#{specimen.concept_id}"
    end
  end
end

# Usage examples:
# Sync::SpecimenSyncJob.perform_async     # Default batch size of 50
# Sync::SpecimenSyncJob.perform_async(25) # Smaller batches
# Sync::SpecimenSyncJob.perform_async(10) # Very small batches for careful processing