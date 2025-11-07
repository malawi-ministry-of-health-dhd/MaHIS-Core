class VisitsService
  include CouchdbSync 
  def create_update_visit(visit_params)
    sync_status = visit_params[:sync_status]  
    if sync_status == 'update'
      close_visit(visit_params)
    elsif sync_status == 'create'
      create_visit(visit_params)
    end
  end
  def create_visit(visit_params)
  
    patientId = visit_params[:patientId] 
    identifier = visit_params[:identifier]
    stage_params = visit_params[:stage]
    
    if identifier.present?
      patient_identifier = PatientIdentifier.where(identifier: identifier)
      patientId = patient_identifier[0][:patient_id]
    end

    checkVisit = Visit.where(patientId: patientId, closedDateTime: nil).first
    if checkVisit.present?
      visit_data = checkVisit.attributes
      visit_data[:identifier] = identifier if identifier.present?
      visit_data[:fullName] =  Patient.find_by(patient_id: patientId).try(:name)
      return visit_data
    end
  
    allowed_fields = visit_params.slice(:patientId, :startDate, :closedDateTime, :programId, :location_id)
    visit = Visit.new(allowed_fields)
    visit.patientId = patientId

    if visit.save
      visit_data = visit.attributes
      visit_data[:fullName] =  Patient.find_by(patient_id: patientId).try(:name)
      visit_data[:identifier] = identifier if identifier.present?
      
      if stage_params.present?
            data = StagesService.new.create_stage(stage_params)
            sync_to_couchdb(data, "stages", data[:identifier])
      end
      visit_data
    end
  end

  def close_visit(visit_params)
    identifier = visit_params[:identifier]

    if identifier.present?
      patient_identifier = PatientIdentifier.where(identifier: identifier)
      patientId = patient_identifier[0][:patient_id]
    end

    visit = Visit.find_by(patientId: patientId)

    unless visit
      return
    end

    existing_stage = Stage.find_by(
      patient_id: visit.patientId,
      location_id: User.current.location_id
    )
    existing_stage.destroy if existing_stage

    closed_datetime = visit_params[:closedDateTime]
    
    visit.update(closedDateTime: closed_datetime)

    visit_data = visit.attributes
    visit_data[:identifier] = identifier if identifier.present?
    visit_data[:fullName] =  Patient.find_by(patient_id: visit.patientId).try(:name)
    visit_data
  end
end