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

    stage.save!
    serialize(stage.reload)
  end

  def update_stage(stage_id, stage_params)
    stage = Stage.find(stage_id)
    stage_name = normalize_stage(stage_params[:stage])

    if stage.stage != stage_name
      stage.stage = stage_name
      stage.arrival_time = Time.current
      stage.save!
    end

    serialize(stage.reload)
  end

  def find_stages(filters = {})
    scope = Stage.includes(patient: :patient_identifiers, visit: {})
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

    {
      id: stage.id,
      patient_id: stage.patient_id,
      visit_id: stage.visit_id,
      location_id: stage.location_id,
      stage: stage.stage,
      status: stage.status,
      arrivalTime: stage.arrival_time,
      arrival_time: stage.arrival_time,
      latest_encounter_time: stage.created_at,
      created_at: stage.created_at,
      updated_at: stage.updated_at,
      fullName: patient&.name,
      identifier: patient_identifier(patient),
      given_name: person_name(patient)&.given_name,
      family_name: person_name(patient)&.family_name,
      gender: patient&.gender
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

  def patient_identifier(patient)
    patient&.patient_identifiers&.find { |id| id.identifier_type == 3 }&.identifier
  end

  def person_name(patient)
    patient&.person&.names&.max_by(&:date_created)
  end

  def find_active_visit(patient_id)
    Visit.find_by(patient_id: patient_id, date_stopped: nil)
  end
end
