class StagesService
  def create_stage(stage_params)
    identifier = stage_params[:identifier]
    patientId = stage_params[:patient_id]
    location_id = stage_params[:location_id]

    if identifier.present?
      patient_identifier = PatientIdentifier.find_by(identifier: identifier)
      patientId = patient_identifier&.patient_id
    end

    existing_stage = Stage.find_by(
      patient_id: patientId,
      location_id: location_id
    )
    existing_stage&.destroy

    activeVisit = Visit.find_by(
      patientId: patientId,
      closedDateTime: nil
    )
    return nil if activeVisit.nil?

    Stage.create(
      patient_id: patientId,
      visit_id: activeVisit.id,
      location_id: location_id,
      status: true,
      arrivalTime: stage_params[:arrivalTime],
      stage: stage_params[:stage]
    )

    {
      **stage_params.to_h.symbolize_keys,
      status: true,
      fullName: Patient.find_by(patient_id: patientId)&.name,
    }
  end

end