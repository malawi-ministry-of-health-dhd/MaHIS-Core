class Api::V1::SyncPatientRecordsController < ApplicationController
  def get_not_sync_ids
    begin
      permitted_params = params.permit!

      previous_sync_date = permitted_params[:previous_sync_date] || 
                          permitted_params.dig(:sync_patient_record, :previous_sync_date)
      enable_site_sync = permitted_params[:enable_site_sync]
      
      validate_inputs(previous_sync_date) if previous_sync_date.present?
      
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

    patient_ids = fetch_distinct_patient_ids(paginated_results)

    {
      sync_patients: sync_patients(patient_ids),
      sync_count: query.distinct.count(:patient_id),
      latest_encounter_datetime: paginated_results.to_a.map(&:date_created).max,
      server_patient_count: calculate_server_patient_count(location_id)
    }
  rescue StandardError => e
    Rails.logger.error("Error in get_not_sync_ids_data: #{e.class.name}")
    Rails.logger.error("Error message: #{e.message}")
    Rails.logger.error("Backtrace: #{e.backtrace.join("\n")}")
    raise
  end

  def validate_inputs(previous_sync_date)
    return if previous_sync_date.blank?
    
    unless previous_sync_date.is_a?(Time) || 
           (previous_sync_date.is_a?(String) && Time.zone.parse(previous_sync_date))
      raise ArgumentError, 'previous_sync_date must be a Time object or valid datetime string'
    end
  end

  def fetch_location_id
    location_id = User.current&.location_id
    raise ActiveRecord::RecordNotFound, 'Current user location not found' if location_id.nil?
    location_id
  end

  def build_base_query(location_id, previous_sync_date)
    query = Encounter.where(location_id: location_id).order('encounter.date_created ASC')
    
    if previous_sync_date.present?
      parsed_date = previous_sync_date.is_a?(Time) ? previous_sync_date : Time.zone.parse(previous_sync_date)
      query = query.where(
        'encounter.date_created BETWEEN ? AND ?',
        parsed_date,
        Time.current
      )
    end
    query
  end

  def fetch_distinct_patient_ids(paginated_results)
    paginated_results.distinct.pluck(:patient_id)
  end

  def calculate_server_patient_count(location_id)
    Patient
      .joins(:encounters)
      .where('encounter.location_id = ?', location_id)
      .distinct
      .count
  end

  def sync_patients(ids)
    results = ids.map do |id|
      begin
        BuildPatientRecordService.build_patient_record(id)
      rescue StandardError => e
        Rails.logger.error("Error building patient record for ID #{id}: #{e.message}")
        Rails.logger.error("Backtrace: #{e.backtrace.join("\n")}")
        nil
      end
    end.compact
    
    Rails.logger.info("Completed sync_patients, processed #{results.size} records")
    results
  end
end