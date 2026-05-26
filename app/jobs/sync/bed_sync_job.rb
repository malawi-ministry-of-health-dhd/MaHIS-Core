# app/jobs/sync/bed_sync_job.rb
module Sync
  class BedSyncJob < BaseSyncJob

    # Sync all non-retired beds to CouchDB using BULK operations
    def perform(batch_size = 5000)
      sync_records_to_couchdb(Bed, 'beds', batch_size) do |model_class|
        model_class.where(retired: false)
      end
    end

    private

    # Keep this aligned with the beds API response payload.
    def get_required_columns
      [
        :bed_id,
        :uuid,
        :bed_number,
        :bed_label,
        :section_id,
        :location_id,
        :bed_status,
        :bed_type,
        :description,
        :retired
      ]
    end

    def prepare_document(bed)
      allocation = bed.current_allocation
      occupancy_status = if allocation.present?
                            BedManagementResponseBuilder::OCCUPIED_STATUS
                          else
                            BedManagementResponseBuilder::UNOCCUPIED_STATUS
                          end

      {
        "bed_id" => bed.bed_id,
        "uuid" => bed.uuid,
        "bed_number" => bed.bed_number,
        "bed_label" => bed.bed_label,
        "section_id" => bed.section_id,
        "location_id" => bed.location_id,
        "bed_status" => bed.bed_status,
        "bed_type" => bed.bed_type,
        "description" => bed.description,
        "occupancy_status" => occupancy_status,
        "current_allocation" => current_allocation(allocation),
        "current_patient" => current_patient(allocation&.patient),
        "retired" => bed.retired
      }
    end

    def generate_document_id(bed)
      "bed_#{bed.bed_id}"
    end

    def current_allocation(allocation)
      return nil unless allocation

      {
        "bed_allocation_id" => allocation.bed_allocation_id,
        "patient_id" => allocation.patient_id,
        "visit_id" => allocation.visit_id,
        "allocated_at" => allocation.allocated_at
      }
    end

    def current_patient(patient)
      return nil unless patient

      {
        "patient_id" => patient.patient_id
      }
    end
  end
end

# Usage - automatically uses bulk sync with enhanced BaseSyncJob:
# Sync::BedSyncJob.perform_async          # Uses default 5000 batch size
# Sync::BedSyncJob.perform_async(10000)   # Larger batches if many beds
# Sync::BedSyncJob.perform_async(2000)    # Smaller batches if needed
