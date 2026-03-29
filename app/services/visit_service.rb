# frozen_string_literal: true

class VisitService
  include CouchdbSync
  include EncounterCreation

  def create_update_visit(visit_params)
    sync_status = visit_params[:sync_status]

    if sync_status == 'update'
      close_visit(visit_params)
    elsif sync_status == 'create'
      create_visit(visit_params)
    end
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

    # Check if visit already exists
    checkVisit = Visit.where(patient_id: patient_id, date_stopped: nil).first
    if checkVisit.present?
      visit_data = checkVisit.attributes
      visit_data[:identifier] = identifier if identifier.present?
      visit_data[:full_name] = Patient.find_by(patient_id: patient_id).try(:name)
      return visit_data
    end

    # Build visit with all required fields
    visit = Visit.new
    
    # Required fields
    visit.patient_id = patient_id
    visit.visit_type_id = visit_params[:visit_type_id]
    visit.date_started = visit_params[:date_started] || Time.now
    visit.date_created = visit_params[:date_created] || Time.now
    visit.creator = visit_params[:provider_id] || User.current&.user_id 
    visit.voided = false
    
    # Optional fields
    visit.date_stopped = visit_params[:date_stopped] if visit_params[:date_stopped].present?
    visit.location_id = visit_params[:location_id] if visit_params[:location_id].present?
    visit.indication_concept_id = visit_params[:indication_concept_id] if visit_params[:indication_concept_id].present?

    if visit.save
      visit_data = visit.attributes
      visit_data[:full_name] = Patient.find_by(patient_id: patient_id).try(:name)
      visit_data[:identifier] = identifier if identifier.present?
      visit_data[:program_id] = visit_params[:program_id]

      if stage_params.present?
        data = StagesService.new.create_stage(stage_params)
        sync_to_couchdb(data, "stages", data[:identifier]) if data.present?
      end
      
      # Create encounter first
      id = EncounterType.find_by_name("visit")
      create_encounter(patient_id, id.encounter_type_id,
        {
          program_id: visit_params[:program_id],
          location_id: visit_params[:location_id],
          encounter_datetime: visit_params[:date_started],
          provider_id: visit_params[:provider_id]
        })

      visit_data
    else
      Rails.logger.error("Visit creation failed: #{visit.errors.full_messages.join(', ')}")
      raise "Visit creation failed: #{visit.errors.full_messages.join(', ')}"
    end
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
    existing_stage.destroy if existing_stage.present?

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


end
