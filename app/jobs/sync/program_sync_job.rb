module Sync
  class ProgramSyncJob < BaseSyncJob
    
    def perform(batch_size = 5000) 
      sync_records_to_couchdb(Program, 'programs', batch_size) do |model_class|
        model_class.where(retired: 0)
      end
    end
    
    private
    
    def get_required_columns
      [
        :program_id,
        :concept_id,
        :name
      ]
    end
    
    def prepare_document(program)
      {
        "program_id" => program.program_id,
        "concept_id" => program.concept_id,
        "name" => program.name,
      }
    end
    
    def generate_document_id(program)
      "program_#{program.program_id}"
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::ProgramSyncJob.perform_async          # Uses default 5000 batch size
# Sync::ProgramSyncJob.perform_async(10000)   # Larger batches if many programs
# Sync::ProgramSyncJob.perform_async(2000)    # Smaller batches if needed