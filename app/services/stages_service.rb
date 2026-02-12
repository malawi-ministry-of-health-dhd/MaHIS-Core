# frozen_string_literal: true

class StagesService
  def create_stage(stage_params)
    patient_id = resolve_patient_id(stage_params)
    raise InvalidParameterError, 'Patient not found' if patient_id.blank?

    active_visit = find_active_visit(patient_id)
    raise InvalidParameterError, "No active visit found for patient #{patient_id}" unless active_visit

    location_id = stage_params[:location_id] || User.current.location_id
    stage_name = normalize_stage(stage_params[:stage])

    stage = Stage.find_or_initialize_by(patient_id: patient_id, location_id: location_id, status: true)
    stage.visit_id = active_visit.visit_id
    stage.status = true

    if stage.new_record?
      stage.stage = stage_name
      stage.arrival_time = Time.current
    elsif stage.stage != stage_name
      # Only stage changes should bump arrival time
      stage.stage = stage_name
      stage.arrival_time = Time.current
    end

    if stage_params[:aetc_visit_number].present? && stage.aetc_visit_number != stage_params[:aetc_visit_number]
      stage.aetc_visit_number = stage_params[:aetc_visit_number]
    end

    stage.save! if stage.changed?
    serialize(stage.reload)
  end

  def update_stage(stage_id, stage_params)
    stage = Stage.find(stage_id)
    stage_name = normalize_stage(stage_params[:stage])

    if stage.stage != stage_name
      stage.stage = stage_name
      stage.arrival_time = Time.current
    end

    if stage_params[:aetc_visit_number].present? && stage.aetc_visit_number != stage_params[:aetc_visit_number]
      stage.aetc_visit_number = stage_params[:aetc_visit_number]
    end

    stage.save! if stage.changed?
    serialize(stage.reload)
  end

  def find_stages(filters = {})
    scope = Stage.includes(patient: %i[person patient_identifiers], visit: {})
                 .joins(:visit)
                 .where(status: true)
                 .where(visit: { date_stopped: nil })

    patient_id = resolve_patient_id(filters)
    scope = scope.where(patient_id: patient_id) if patient_id.present?
    scope = scope.where(location_id: filters[:location_id]) if filters[:location_id].present?
    scope = scope.where(stage: normalize_stage(filters[:stage])) if filters[:stage].present?

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
      uuid: patient_uuid(patient) || stage.patient_id.to_s,
      patient_id: stage.patient_id,
      visit_uuid: stage.visit&.uuid,
      arrival_time: stage.arrival_time,
      latest_encounter_time: latest_encounter&.encounter_datetime || stage.created_at,
      last_encounter_creator: encounter_creator_name(latest_encounter),
      disposition_type: stage.disposition_type,
      triage_result: stage.triage_result,
      given_name: person_name(patient)&.given_name,
      family_name: person_name(patient)&.family_name,
      gender: patient&.gender,
      aetc_visit_number: stage.aetc_visit_number,
      patient_care_area: stage.patient_care_area,
      category: normalize_category(stage.stage),
      created_at: stage.created_at,
      updated_at: stage.updated_at,
      department: stage.department,
      destination: stage.destination
    }
  end

  private

  def resolve_patient_id(params)
    return params[:patient_id] if params[:patient_id].present?
    return nil if params[:identifier].blank?

    PatientIdentifier.find_by(identifier: params[:identifier])&.patient_id
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

  def patient_identifier(patient)
    patient&.patient_identifiers&.find { |id| id.identifier_type == 3 }&.identifier
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

  def encounter_creator_name(encounter)
    return nil unless encounter&.creator

    User.find_by(user_id: encounter.creator)&.name
  end
end
