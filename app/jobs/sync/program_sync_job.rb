# app/jobs/sync/program_sync_job.rb
module Sync
  class ProgramSyncJob < BaseSyncJob
    
    # Sync all programs to CouchDB
    def perform(batch_size = 100)
      sync_records_to_couchdb(Program, 'programs', batch_size) do |model_class|
        model_class.where(retired: 0)
      end
    end
    
    private
    
    def prepare_document(program)
      {
        "type" => "program",
        "program_id" => program.program_id,
        "concept_id" => program.concept_id,
        "name" => program.name,
        "description" => program.description,
        "creator" => program.creator,
        "changed_by" => program.changed_by,
        "retired" => program.retired,
        "uuid" => program.uuid,
        "date_created" => program.date_created&.iso8601,
        "date_changed" => program.date_changed&.iso8601,
        "synced_at" => Time.current.iso8601
      }
    end
    
    def generate_document_id(program)
      "program_#{program.program_id}"
    end
  end
end

# Usage examples:
# Sync::ProgramSyncJob.perform_async(50)  # Smaller batches
# Sync::ProgramSyncJob.perform_async      # Default batch size of 100