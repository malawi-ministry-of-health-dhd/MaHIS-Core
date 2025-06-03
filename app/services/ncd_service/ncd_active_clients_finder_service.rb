class NcdActiveClientsFinderService

  def find_active_clients()
    service = FacilityService.new
    result = service.list_facility_codes

    result.each do |facility|
      ncd_active_patients(facility)
    end
  end

  def ncd_active_patients(location_id)
    @current_date = Date.current
    @location_id = location_id

    base_patients = Patient.joins(encounters: [:program, :type])
                          .where(program: { program_id: 32 })
                          .where(encounters: { location_id: @location_id })
                          .where(encounter_type: { name: ['PATIENT REGISTRATION', 'REGISTRATION'] })
                          .distinct
    
    MongoSyncService.new.sync_patients_to_mongo(base_patients, @location_id)
    
    total_records = base_patients.count
    results = paginate(base_patients)

    render json: {
      count: total_records,
      results: results
    }, status: :ok
  end
end