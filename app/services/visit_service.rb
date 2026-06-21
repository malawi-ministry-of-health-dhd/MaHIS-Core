# frozen_string_literal: true

class VisitService
  include CouchdbSync
  include EncounterCreation

  def create_update_visit(visit_params)
    sync_status = visit_params[:sync_status]
    operation_type = sync_status == 'update' ? 'visit.close' : 'visit.create'

    result = PatientRecordOperationGuard.run!(
      patient_id: visit_params[:patient_id],
      operation_type: operation_type,
      payload: visit_params,
      target_type: 'Visit'
    ) do
      if sync_status == 'update'
        close_visit(visit_params)
      elsif sync_status == 'create'
        create_visit(visit_params)
      end
    end

    return skipped_visit_payload(result.receipt, visit_params) if result.skipped?

    result.value
  end


  def create_visit(visit_params)
    patient_id = visit_params[:patient_id]
    identifier = visit_params[:identifier]
    stage_params = visit_params[:stage]

    if identifier.present?
      patient_identifier = PatientIdentifier.find_by(identifier: identifier, identifier_type: 3) ||
                           PatientIdentifier.unscoped.find_by(identifier: identifier, identifier_type: 3, voided: 0)
      patient_id = patient_identifier[:patient_id] if patient_identifier.present?
    end

    raise InvalidParameterError, 'Patient could not be resolved for visit' if patient_id.blank?

    encounter_type = visit_encounter_type!
    existing_visit = Visit.where(patient_id:, date_stopped: nil).first
    if existing_visit
      ensure_visit_encounter!(existing_visit, encounter_type, visit_params)
      return visit_payload(existing_visit, visit_params, identifier)
    end

    visit = Visit.new
    visit.patient_id = patient_id
    visit.visit_type_id = visit_params[:visit_type_id]
    visit.date_started = visit_params[:date_started] || Time.now
    visit.date_created = visit_params[:date_created] || Time.now
    visit.creator = visit_params[:provider_id] || User.current&.user_id
    visit.voided = false
    visit.date_stopped = visit_params[:date_stopped] if visit_params[:date_stopped].present?
    visit.location_id = visit_params[:location_id] if visit_params[:location_id].present?
    visit.indication_concept_id = visit_params[:indication_concept_id] if visit_params[:indication_concept_id].present?

    Visit.transaction do
      visit.save!
      ensure_visit_encounter!(visit, encounter_type, visit_params)
    end

    if stage_params.present?
      data = StagesService.new.create_stage(stage_params)
      sync_to_couchdb(data, 'stages', data[:identifier]) if data.present?
    end

    visit_payload(visit, visit_params, identifier)
  end

  def close_visit(visit_params)
    identifier = visit_params[:identifier]
    patient_id = nil

    if identifier.present?
      patient_identifier = PatientIdentifier.find_by(identifier: identifier, identifier_type: 3) ||
                           PatientIdentifier.unscoped.find_by(identifier: identifier, identifier_type: 3, voided: 0)
      patient_id = patient_identifier[:patient_id] if patient_identifier.present?
    end

    patient_id = visit_params[:patient_id] || visit_params[:patient_id] unless patient_id.present?

    visit = Visit.find_by(patient_id: patient_id, date_stopped: nil)

    unless visit.present?
      Rails.logger.warn("No open visit found for patient #{patient_id}")
      return
    end

    existing_stage = Stage.find_by(
      patient_id: visit.patient_id,
      location_id: visit_params[:location_id] || (User.current&.location_id)
    )
    if existing_stage.present?
      StagesService.new.broadcast_stage_deletion(existing_stage)
      existing_stage.destroy
    end

    closed_datetime = visit_params[:date_stopped] || Time.now

    visit.update(
      date_stopped: closed_datetime,
      changed_by: User.current&.user_id || 1,
      date_changed: Time.now
    )

    visit_data = visit.attributes
    visit_data[:identifier] = identifier if identifier.present?
    visit_data[:full_name] = Patient.find_by(patient_id: visit.patient_id).try(:name)
    visit_data
  end
  def self.next_daily_visit_number!
    date_key = Time.zone.today.strftime('%Y-%m-%d')
    property_name = "visit_number_counter:#{date_key}"
    location_key = (User.current.location_id || 0).to_s

    GlobalProperty.transaction do
      counter = GlobalProperty.lock.find_or_create_by!(property: property_name, location_id: location_key) do |record|
        record.property_value = '0'
        record.description = 'Daily AETC visit number counter'
        record.uuid = SecureRandom.uuid
      end

      next_number = counter.property_value.to_i + 1
      counter.update!(property_value: next_number.to_s)
      next_number
    end
  end

  private

  def visit_encounter_type!
    EncounterType.find_by('LOWER(name) = ?', 'visit') ||
      raise(InvalidParameterError, 'Encounter type "Visit" is not configured')
  end

  def ensure_visit_encounter!(visit, encounter_type, visit_params)
    encounter_id = create_encounter(
      visit.patient_id,
      encounter_type.encounter_type_id,
      {
        program_id: visit_params[:program_id],
        location_id: visit_params[:location_id],
        encounter_datetime: visit_params[:date_started] || visit.date_started,
        provider_id: visit_params[:provider_id]
      }
    )
    raise InvalidParameterError, 'Visit encounter could not be created' if encounter_id.blank?

    encounter = Encounter.find(encounter_id)
    encounter.update!(visit:) unless encounter.visit_id == visit.visit_id
  end

  def visit_payload(visit, visit_params, identifier)
    visit.attributes.merge(
      'identifier' => identifier.presence,
      'full_name' => Patient.find_by(patient_id: visit.patient_id).try(:name),
      'program_id' => visit_params[:program_id],
      'location_id' => visit.location_id.to_s
    ).compact
  end

  def skipped_visit_payload(receipt, visit_params)
    visit = Visit.find_by(visit_id: receipt&.target_id)
    return visit.attributes if visit

    visit_params
  end


end
