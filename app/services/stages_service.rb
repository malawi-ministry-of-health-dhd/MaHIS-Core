# frozen_string_literal: true

class StagesService
  MAX_STAGE_LOCATION_DEPTH = 5

  def create_stage(stage_params)
    patient_id = resolve_patient_id(stage_params)
    raise InvalidParameterError, 'Patient not found' if patient_id.blank?

    active_visit = find_active_visit(patient_id, stage_params[:program_id])
    raise InvalidParameterError, "No active visit found for patient #{patient_id}" unless active_visit

    result = PatientRecordOperationGuard.run!(
      patient_id: patient_id,
      operation_type: 'stage.upsert',
      payload: stage_params,
      target_type: 'Stage'
    ) do
      create_or_update_stage(patient_id, active_visit, stage_params)
    end

    return skipped_stage_payload(result.receipt, stage_params) if result.skipped?

    result.value
  end

  def create_or_update_stage(patient_id, active_visit, stage_params)

    location_id = resolve_stage_location(stage_params[:location_id])
    stage_name = normalize_stage(stage_params[:stage])

    # Keep one stage record per active visit and update it as patient moves.
    stage = Stage.where(visit_id: active_visit.visit_id).order(updated_at: :desc).first

    if stage.nil?
      stage = Stage.new(
        patient_id: patient_id,
        visit_id: active_visit.visit_id,
        location_id: location_id,
        status: true
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
    # Record the program the patient was sent from (e.g. OPD -> HTS) once, and
    # keep it as the patient moves between stages of the destination program.
    if stage_params[:referring_program_id].present? && stage.referring_program_id.blank?
      stage.referring_program_id = stage_params[:referring_program_id]
    end
    assign_arrival_time(stage, stage_params)
    assign_stage_metadata(stage, stage_params)

    if stage.stage != stage_name
      stage.stage = stage_name
    end

    was_new_record = stage.new_record?
    has_changes = stage.new_record? || stage.changed?

    stage.save! if has_changes
    stage_data = serialize(stage.reload, latest_encounter_time: Time.current)

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

  def serialize(stage, latest_encounter_time: nil)
    patient = stage.patient
    latest_encounter = latest_visit_encounter(stage)
    {
      id: stage.id,
      location_id: stage.location_id.to_s,
      stage: stage.stage,
      status: stage.status,
      identifier: BuildPatientRecordService::PatientIdentifierService.patient_identifier(patient,3),
      visit_id: stage.visit_id,
      uuid: patient_uuid(patient) || stage.patient_id.to_s,
      patient_id: stage.patient_id,
      visit_uuid: stage.visit&.uuid,
      arrival_time: stage.arrival_time,
      program_id: stage.program_id,
      referring_program_id: stage.referring_program_id,
      latest_encounter_time: latest_encounter_time || latest_encounter&.encounter_datetime || stage.created_at,
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

  def broadcast_stage_deletion(stage)
    stage_data = serialize(stage)
    stage_data[:status] = false
    broadcast_stage_update('stage_deleted', stage_data)
  end

  # Key the CouchDB stage doc by identifier + program so a patient can hold one
  # stage per program simultaneously (e.g. an open OPD stage AND an HTS stage
  # after "Send to HTS"). Keying by identifier alone let each program's write
  # clobber the other, dropping a stage from offline devices. Shared by the
  # stages controller and VisitService so every stage write uses one scheme.
  def couchdb_doc_id(data)
    identifier = data[:identifier] || data[:patient_id]
    program_id = data[:program_id]
    program_id.present? ? "#{identifier}_#{program_id}" : identifier.to_s
  end

  private

  def skipped_stage_payload(receipt, stage_params)
    stage = Stage.find_by(id: receipt&.target_id)
    return serialize(stage.reload, latest_encounter_time: Time.current) if stage

    stage_params
  end

  def apply_stage_updates(stage, stage_params)
    stage_name = normalize_stage(stage_params[:stage])
    assign_arrival_time(stage, stage_params)
    assign_stage_metadata(stage, stage_params)

    if stage.stage != stage_name
      stage.stage = stage_name
    end

    if stage_params[:visit_number].present? && stage.visit_number != stage_params[:visit_number]
      stage.visit_number = stage_params[:visit_number]
    end

    has_changes = stage.changed?
    stage.save! if has_changes
    stage_data = serialize(stage.reload, latest_encounter_time: Time.current)

    broadcast_stage_update('stage_updated', stage_data) if has_changes
    stage_data
  end

  # The authenticated user's assigned facility is authoritative for queue
  # placement. Patient records can carry the facility where they were
  # registered, and older clients may submit that stale location_id.
  #
  # Sub-locations of the user's own facility are the exception: IPD queues are
  # per ward, so a submitted ward (or one of its sections) is kept as-is —
  # otherwise the ward chosen at admission is lost and the ward-scoped
  # pre-admission list can never match the stage. Anything outside the user's
  # facility still falls back to the facility.
  def resolve_stage_location(submitted_location_id)
    facility_id = User.current&.location_id
    return submitted_location_id if facility_id.blank?
    return facility_id if submitted_location_id.blank? || same_location?(submitted_location_id, facility_id)

    within_facility?(submitted_location_id, facility_id) ? submitted_location_id : facility_id
  end

  def same_location?(left, right)
    left.to_s.strip == right.to_s.strip
  end

  # Walks parent_location upwards looking for the facility. Wards are parented
  # to their facility and sections to their ward, so the chain is short; the
  # bound just stops a malformed cycle from looping forever.
  def within_facility?(location_id, facility_id)
    location = Location.find_by(location_id: location_id)

    MAX_STAGE_LOCATION_DEPTH.times do
      break if location.nil? || location.parent_location.blank?
      return true if same_location?(location.parent_location, facility_id)

      location = location.parent
    end

    false
  end

  def resolve_patient_id(params)
    return params[:patient_id] if params[:patient_id].present?
    return nil if params[:identifier].blank?

    patient_identifier = PatientIdentifier.find_by(identifier: params[:identifier], identifier_type: 3) ||
                         PatientIdentifier.unscoped.find_by(identifier: params[:identifier], identifier_type: 3, voided: 0)
    patient_identifier&.patient_id
  end

  def payload_arrival_time(params)
    params[:arrival_time].presence || params['arrival_time'].presence
  end

  def assign_arrival_time(stage, params)
    arrival_time = payload_arrival_time(params)
    stage.arrival_time = arrival_time if arrival_time.present?
  end

  def assign_stage_metadata(stage, params)
    %i[disposition_type patient_care_area department destination].each do |field|
      value = params[field].presence || params[field.to_s].presence
      stage.public_send("#{field}=", value) if value.present?
    end
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

  def find_active_visit(patient_id, program_id = nil)
    scope = Visit.where(patient_id: patient_id, date_stopped: nil)
    # A stage belongs to a visit of the same program. Without this filter a
    # stage requested for one program (e.g. OPD=14) silently attaches to an
    # open visit of a different program (e.g. AETC=30), leaving the stage and
    # its visit disagreeing on program. Legacy visits with a NULL program_id
    # are still matched so they keep working.
    scope = scope.where('program_id = ? OR program_id IS NULL', program_id) if program_id.present?
    scope.first
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
