class Api::V1::SyncPatientRecordsController < ApplicationController
  def get_not_sync_ids
    begin
      permitted_params = params.permit(
        :previous_sync_date,
        :enable_site_sync,
        :page,
        :page_size,
        sync_patient_record: [:previous_sync_date, :page, :page_size]
      )

      previous_sync_date = permitted_params[:previous_sync_date] || 
                          permitted_params.dig(:sync_patient_record, :previous_sync_date)
      enable_site_sync = permitted_params[:enable_site_sync]
      
      records = get_not_sync_ids_data(previous_sync_date, enable_site_sync)
      render json: records, status: :ok
    rescue StandardError => e
      Rails.logger.error("Error in get_not_sync_ids: #{e.class.name}")
      Rails.logger.error("Error message: #{e.message}")
      Rails.logger.error("Backtrace: #{e.backtrace.join("\n")}")
      render json: { error: e.message }, status: :internal_server_error
    end
  end

  private

  def get_not_sync_ids_data(previous_sync_date = nil, enable_site_sync = nil)
    location_id = fetch_location_id
    query = build_base_query(location_id, previous_sync_date)
    paginated_results = paginate(query)

    # Ensure unique patient_ids by grouping and ordering
    patient_ids = paginated_results.pluck('patient.patient_id, MAX(encounters.date_created) as latest_encounter_date')

    {
      sync_patients: sync_patients(patient_ids),
      sync_count: query.unscope(:select, :order, :group).distinct.count(:patient_id),
      latest_encounter_datetime: paginated_results.last&.latest_encounter_date,
      server_patient_count: calculate_server_patient_count(location_id)
    }
  rescue StandardError => e
    Rails.logger.error("Error in get_not_sync_ids_data: #{e.class.name}")
    Rails.logger.error("Error message: #{e.message}")
    Rails.logger.error("Backtrace: #{e.backtrace.join("\n")}")
    raise
  end

  def validate_inputs(previous_sync_date)
    return unless previous_sync_date.present?
    
    unless previous_sync_date.is_a?(Time) || previous_sync_date.is_a?(String)
      raise ArgumentError, 'previous_sync_date must be a Time object or valid datetime string'
    end
  end

  def fetch_location_id
    location_id = User.current&.location_id
    raise ActiveRecord::RecordNotFound, 'Current user location not found' if location_id.nil?
    location_id
  end

  def build_base_query(location_id, previous_sync_date)
    query = Patient
      .joins(:encounters)
      .select('patient.patient_id, MAX(encounters.date_created) as latest_encounter_date')
      .where(encounters: { location_id: location_id })
      
    if previous_sync_date.present?
      query = query.where(
        'encounters.date_created BETWEEN ? AND ?',
        previous_sync_date,
        Time.current.strftime('%Y-%m-%d %H:%M:%S')
      )
    end
      
    query = query.group('patient.patient_id')
    # Add patient_id to the order to ensure deterministic sorting
    query.order('latest_encounter_date ASC, patient.patient_id ASC')
  end

  def fetch_latest_encounter_datetime(query)
    query.maximum('encounters.date_created')
  end

  def calculate_server_patient_count(location_id)
    Patient
      .joins(:encounters)
      .where('encounter.location_id = ?', location_id) # Keep as `encounter.location_id` if correct
      .distinct
      .count
  end

  def sync_patients(ids)
    results = ids.map do |id|
      begin
        BuildPatientRecordService.build_patient_record(id[0])
      rescue StandardError => e
        Rails.logger.error("Error building patient record for ID #{id}: #{e.message}")
        nil
      end
    end.compact
    Rails.logger.info("Completed sync_patients, processed #{results.size} records")
    results
  end
end