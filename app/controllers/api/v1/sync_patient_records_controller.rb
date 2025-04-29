class Api::V1::SyncPatientRecordsController < ApplicationController

   # Add a new endpoint to trigger syncing manually if needed
  def trigger_sync
    location_id = fetch_location_id
    since_date = params[:since_date]
    
    # Queue the batch job to sync all patients for this location
     BatchPatientSyncJob.perform_async(location_id, since_date)
  end
  def get_not_sync_ids
    params.permit(
      :previous_sync_date,
      :enable_site_sync,
      :page,
      :page_size,
      sync_patient_record: [:previous_sync_date, :page, :page_size]
    )

    location_id = fetch_location_id
    page = params[:page].to_i > 0 ? params[:page].to_i : 1
    per_page = params[:page_size].to_i > 0 ? params[:page_size].to_i : 1
    
    # Optional: filter by encounter_datetime if you want
    updated_since = params[:previous_sync_date].present? ? Time.parse(params[:previous_sync_date]) : nil
    
    # Base query that only reads data (doesn't trigger syncing)
    query = PatientRecord.where("record.location_id" => location_id)
    query = query.where(:encounter_datetime.gte => updated_since) if updated_since
    
    # Pagination with stable ordering (add _id as secondary sort to ensure consistency)
    patients = query.order_by(encounter_datetime: :desc, _id: :asc)
                    .skip((page - 1) * per_page)
                    .limit(per_page)

    # Count all patients for the location (no pagination)
    total_for_location = PatientRecord.where("record.location_id" => location_id).count
  
    # if(total_for_location <= 0) 
    #   trigger_sync()
    # end
    trigger_sync()
    # Build response
    render json: {
      sync_patients: patients.map(&:record),
      sync_count: patients.count,
      latest_encounter_datetime: patients.first&.encounter_datetime,
      server_patient_count: total_for_location,
    }
  end
  
 
  
  private
  
  def fetch_location_id
    location_id = User.current&.location_id
    raise ActiveRecord::RecordNotFound, 'Current user location not found' if location_id.nil?
    location_id
  end
end