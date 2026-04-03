# frozen_string_literal: true

class StagesService
  def create_stage(stage_params)
    patient_id = resolve_patient_id(stage_params)
    raise InvalidParameterError, 'Patient not found' if patient_id.blank?

    active_visit = find_active_visit(patient_id)
    raise InvalidParameterError, "No active visit found for patient #{patient_id}" unless active_visit

    location_id = stage_params[:location_id] || User.current.location_id
    stage_name = normalize_stage(stage_params[:stage])

    # Keep one stage record per active visit and update it as patient moves.
    stage = Stage.where(visit_id: active_visit.visit_id).order(updated_at: :desc).first

    if stage.nil?
      stage = Stage.new(
        patient_id: patient_id,
        visit_id: active_visit.visit_id,
        location_id: location_id,
        status: true,
        arrival_time: Time.current
      )
    end

    if Program.find_by_name("AETC Program").id == stage_params[:program_id]
      stage.visit_number = VisitService.next_daily_visit_number! 
    end

    stage.program_id = stage_params["program_id"]
    stage.patient_id = patient_id
    stage.visit_id = active_visit.visit_id
    stage.location_id = location_id
    stage.status = true

    if stage.stage != stage_name
      stage.stage = stage_name
      stage.arrival_time = Time.current
    end

    was_new_record = stage.new_record?
    has_changes = stage.new_record? || stage.changed?

    stage.save! if has_changes
    stage_data = serialize(stage.reload)

    broadcast_stage_update(was_new_record ? 'stage_created' : 'stage_updated', stage_data) if has_changes
    stage_data
  end

  def update_stage(stage_id, stage_params)
    stage = Stage.find(stage_id)
    apply_stage_updates(stage, stage_params)
  end

  def update_stage_by_visit(visit_id, stage_params)
    stage = Stage.where(visit_id: visit_id).order(updated_at: :desc).first
    raise InvalidParameterError, "No stage record found for visit #{visit_id}" unless stage

    apply_stage_updates(stage, stage_params)
  end

  def find_stages(filters = {})
    scope = Stage.includes(patient: %i[person patient_identifiers], visit: {})
                 .joins(:visit)
                 .where(status: true)
                 .where(visit: { date_stopped: nil })

    patient_id = resolve_patient_id(filters)
    program_id = filters[:program_id]

    scope = scope.where(patient_id: patient_id) if patient_id.present?
    scope = scope.where(location_id: filters[:location_id]) if filters[:location_id].present?
    scope = scope.where(stage: normalize_stage(filters[:stage])) if filters[:stage].present?
    scope = scope.where(program_id: program_id) if program_id.present?

    scope.order(updated_at: :desc)
  end

  def active_stages(location_id)
    find_stages(location_id: location_id)
  end

  def find_stage(id)
    Stage.find(id)
  end

  def serialize(stage)
    patient = stage.patient
    latest_encounter = latest_visit_encounter(stage)
    {
      id: stage.id,
      location_id: stage.location_id,
      stage: stage.stage,
      status: stage.status,
      identifier: BuildPatientRecordService::PatientIdentifierService.patient_identifier(patient,3),
      visit_id: stage.visit_id,
      uuid: patient_uuid(patient) || stage.patient_id.to_s,
      patient_id: stage.patient_id,
      visit_uuid: stage.visit&.uuid,
      arrival_time: stage.arrival_time,
      program_id: stage.program_id,
      latest_encounter_time: latest_encounter&.encounter_datetime || stage.created_at,
      last_encounter_creator: encounter_creator_name(latest_encounter,patient),
      disposition_type: stage.disposition_type,
      triage_result: stage.triage_result,
      given_name: person_name(patient)&.given_name,
      family_name: person_name(patient)&.family_name,
      gender: patient&.gender,
      visit_number: stage.visit_number,
      patient_care_area: stage.patient_care_area,
      category: normalize_category(stage.stage),
      created_at: stage.created_at,
      updated_at: stage.updated_at,
      department: stage.department,
      destination: stage.destination
    }
  end

  private

  def apply_stage_updates(stage, stage_params)
    stage_name = normalize_stage(stage_params[:stage])

    if stage.stage != stage_name
      stage.stage = stage_name
      stage.arrival_time = Time.current
    end

    if stage_params[:visit_number].present? && stage.visit_number != stage_params[:visit_number]
      stage.visit_number = stage_params[:visit_number]
    end

    has_changes = stage.changed?
    stage.save! if has_changes
    stage_data = serialize(stage.reload)

    broadcast_stage_update('stage_updated', stage_data) if has_changes
    stage_data
  end

  def resolve_patient_id(params)
    return params[:patient_id] if params[:patient_id].present?
    return nil if params[:identifier].blank?

    patient_identifier = PatientIdentifier.find_by(identifier: params[:identifier], identifier_type: 3) ||
                         PatientIdentifier.unscoped.find_by(identifier: params[:identifier], identifier_type: 3, voided: 0)
    patient_identifier&.patient_id
  end

  def normalize_stage(stage)
    value = stage.to_s.upcase
    raise InvalidParameterError, 'stage is required' if value.blank?
    raise InvalidParameterError, "#{stage} is not a valid stage" unless Stage::VALID_STAGES.include?(value)

    value
  end

  def normalize_category(stage)
    return 'screening' if stage.to_s.upcase == 'SCREEN'

    stage.to_s.downcase
  end

  def person_name(patient)
    patient&.person&.names&.max_by(&:date_created)
  end

  def patient_uuid(patient)
    patient&.person&.uuid || patient&.uuid
  end

  def find_active_visit(patient_id)
    Visit.find_by(patient_id: patient_id, date_stopped: nil)
  end

  def latest_visit_encounter(stage)
    return nil unless stage.visit_id

    Encounter.where(visit_id: stage.visit_id).order(encounter_datetime: :desc).first
  end

  def encounter_creator_name(encounter, patient)
    if encounter&.creator
      User.find_by(user_id: encounter.creator)&.name
    else
      User.find_by(user_id: patient.creator)&.name
    end
  end

  def broadcast_stage_update(event_name, data)
    location_id = data[:location_id] || data['location_id']
    return if location_id.blank?

    payload = {
      event: event_name,
      data: data
    }

    # Primary OPD realtime stream
    ActionCable.server.broadcast("stage_updates_channel_#{location_id}", payload)
    # Fallback stream that already exists in deployed environments
    ActionCable.server.broadcast("client_details_channel_#{location_id}", payload)
  end
end
