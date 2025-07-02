# frozen_string_literal: true

ENCOUNTER_TYPE_MAPPING = {
  vitals: 'VITALS',
  diagnosis: 'DIAGNOSIS',
  substance_abuse: 'ASSESSMENT',
  screening: 'SCREENING',
  lab_orders: 'LAB ORDERS',
  lab_results: 'LAB RESULTS',
  family_medical_history:'FAMILY MEDICAL HISTORY',
  complications:'COMPLICATIONS',
  tb_reception:'TB RECEPTION',
  hiv_status_at_enrollment:'HIV STATUS AT ENROLLMENT',
  medical_history:'MEDICAL HISTORY',
  patient_registration:'PATIENT REGISTRATION',
  patient_outcome: 'PATIENT OUTCOME',
  treatment:'TREATMENT',
  notes:'NOTES',
  allergies:'MEDICAL HISTORY',
}.freeze
class SavePatientRecordService
  def create_patient_record(record)
    # Extract required fields
    required_fields = {
      program_id: record.dig('program_id'),
      provider_id: record.dig('provider_id'),
      location_id: record.dig('location_id'),
      encounter_datetime: record.dig('encounter_datetime')
    }

    ids = {
      national_id: record.dig('otherPersonInformation', 'nationalID'),
      ichis_id: record.dig('otherPersonInformation', 'ichisID'),
      birth_id: record.dig('otherPersonInformation', 'birthID')
    }

    return if required_fields.values.any? { |value| value.nil? || value.to_s.empty? }
    return unless (patient_id = save_person_information(record)[:patient_id])

    validate_id(ids[:national_id], ids[:birth_id],ids[:ichis_id])
    
    %i[
      create_guardian
      save_birthday_data
      save_vitals_data
      save_diagnosis_data
      save_enrollment_data
      save_substance_abuse_data
      save_screening_data
      save_lab_orders_data
      save_lab_results_data
      save_vaccines
      save_appointments
      send_sms
      void_vaccine
      void_lab_order
      save_outcome
      save_medication_order
      create_ncd_identifier
      save_notes_and_pharmalogical_notes
      save_allergies
      save_dispensation_data
      save_all_observations
    ].each { |operation| send(operation, patient_id, record) }

    patient_data = BuildPatientRecordService.build_patient_record(patient_id)
    patient_record = PatientRecord.find_or_initialize_by(patient_id: patient_id)
      
    # If we couldn't build valid patient data, mark as failed and return
    if patient_data.nil?
      Rails.logger.error("Failed to build data for patient #{patient_id}")
      patient_record.update(sync_status: 'failed', last_sync_at: Time.current)
      return
    end
    
    # Update the record
    patient_record.record = patient_data
    patient_record.encounter_datetime = patient_data[:encounter_datetime] if patient_data[:encounter_datetime]
    patient_record.last_sync_at = Time.current
    patient_record.sync_status = 'synced'
    patient_record.save!

    patient_data
  end

  def save_person_information(record)
    if record[:personInformation] && record[:saveStatusPersonInformation] == 'pending'
      # Create person and get data
      person = create_person(record[:personInformation])
      patient = create_patient(person.person_id, record)
      identifier = BuildPatientRecordService.patient_identifier(patient, 3)
      patient_id = person.person_id

      create_ids(record[:otherPersonInformation], patient_id)
      if record[:otherPersonInformation][:ichisID].present?
        tei = record[:otherPersonInformation][:TEI]
        ichis_data = { identifier: identifier, TEI: tei }
        FhirService.sendEMRIdToMediator(ichis_data)  
      end
      enroll_program(patient_id, record)
      create_encounter(patient_id, 5, record)

      record[:ID] = identifier
      record[:patientID] = patient_id
      record[:saveStatusPersonInformation] = 'complete'
      return { patient_id: patient_id, id: identifier }
    end

    { patient_id: record[:patientID], id: record[:ID] }
  end

  def create_person(person_info)
    person = Person.transaction do
      person = person_service.create_person(person_info)
      person_service.create_person_name(person, person_info)
      person_service.create_person_address(person, person_info)
      person_service.create_person_attributes(person, person_info)

      person
    end
  end

  def create_patient(person_id, record)
    person = Person.find(person_id)
    program = Program.find(record[:program_id])

    service = PatientService.new
    service.create_patient(program, person, '', record[:ID])
  end

  def create_ids(otherPersonInformation, patient_id)
    if otherPersonInformation[:nationalID].present?
      PatientIdentifierService.create(
        patient_id: patient_id,
        identifier: otherPersonInformation[:nationalID],
        identifier_type: 28
      )
    end
    return unless otherPersonInformation[:birthID].present?

    PatientIdentifierService.create(
      patient_id: patient_id,
      identifier: otherPersonInformation[:birthID],
      identifier_type: 23
    )

    return unless otherPersonInformation[:ichisID].present?

    PatientIdentifierService.create(
      patient_id: patient_id,
      identifier: otherPersonInformation[:ichisID],
      identifier_type: 10
    )
  end

  def create_ncd_identifier(patient_id, record)
    return unless record[:NcdID].present?
    if(record[:NcdID] == "-")
      PatientIdentifierService.create(patient_id: patient_id,
      identifier: find_next_available_ncd_number(record[:location_id]),
      identifier_type: 31)
    end
  end
  def find_next_available_ncd_number(location_id)
      current_ncd_code = global_property("site_prefix_#{location_id}")&.property_value
      raise 'Global property `site_prefix` not set' unless current_ncd_code

      type = PatientIdentifierType.find_by_name('NCD Number')
      current_ncd_number_identifiers = PatientIdentifier.where(identifier_type: type)

      unless current_ncd_number_identifiers.nil?
        assigned_ncd_ids = current_ncd_number_identifiers.collect do |identifier|
          Regexp.last_match(1).to_i if identifier.identifier =~ /#{current_ncd_code}-NCD- *(\d+)/
        end.compact
      end

      next_available_number = nil

      if assigned_ncd_ids.empty?
        next_available_number = 1
      else
        assigned_numbers = assigned_ncd_ids.sort

        possible_number_range = global_property('ncd_number_range')&.property_value&.to_i || 100_000

        possible_identifiers = Array.new(possible_number_range) { |i| (i + 1) }
        next_available_number = (possible_identifiers - assigned_numbers).first
      end   

      "#{current_ncd_code}-NCD-#{next_available_number}"
  end
  def global_property(name)
    GlobalProperty.find_by property: name
  end
  def enroll_program(patient_id, record)
    if PatientProgram.where(program_id: record[:program_id], patient_id: patient_id)
                     .exists?
      return
    end

    new_patient_program = PatientProgram.create!(
      program_id: record[:program_id],
      date_enrolled: record[:encounter_datetime] || Time.now,
      location_id: record[:location_id],
      patient_id: patient_id
    )

    if new_patient_program.errors.empty?
      Rails.logger.info('Successfully created patient program')
    else
      Rails.logger.error(new_patient_program.errors.full_messages)
      raise new_patient_program.errors.full_messages.join(', ')
    end
  end

  def validate_id(national_id, birth_id, ichis_id)
    validate_identifier(national_id, type: :national) &&
      validate_identifier(birth_id, type: :birth)
  end

  def validate_identifier(id, type:)
    return true if id.nil? || id.empty?

    identifier_type_id = type == :national ? 28 : 23
    !identifier_exists?(identifier_type_id, id)
  end

  def identifier_exists?(type_id, id)
    return false unless type_id

    identifier_type = PatientIdentifierType.find(type_id)
    PatientService.new.find_patients_by_identifier(id, identifier_type).any?
  end

  def create_guardian(patient_id, record)
    return unless record[:saveStatusGuardianInformation] == 'pending'

    return unless guardian_info_complete?(record)

    begin
      guardian_data = create_person(record[:guardianInformation][:unsaved][0])
      guardian_id = guardian_data.person_id

      create_relation(
        guardian_id: guardian_id,
        relationship_type_id: record[:otherPersonInformation][:relationshipID],
        person_id: patient_id
      )
      record[:saveStatusGuardianInformation] = 'complete'
    rescue StandardError => e
      Rails.logger.error("Failed to save guardian information: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end

  def guardian_info_complete?(record)
    guardian = record.dig(:guardianInformation, :unsaved, 0)
    relationship_id = record.dig(:otherPersonInformation, :relationshipID)

    guardian&.dig(:given_name).present? &&
      guardian&.dig(:family_name).present? &&
      relationship_id.present?
  end

  def create_relation(guardian_id:, relationship_type_id:, person_id:)
    begin
      relationship_type = RelationshipType.find relationship_type_id
      person = Person.find guardian_id
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error(e.message)
    end
    service = PersonRelationshipService.new Person.find(person_id)
    service.create_relationship person, relationship_type
  end

  def save_birthday_data(patient_id, record)
    return unless record[:saveStatusBirthRegistration] == 'pending'

    return unless record[:birthRegistration].present? && record[:birthRegistration].any?

    begin
      encounter_id = create_encounter(patient_id, 5, record)
      save_obs(
        encounter_id: encounter_id,
        observations: record[:birthRegistration],
        location_id: record[:location_id]
      )
      record[:saveStatusBirthRegistration] = 'complete'
    rescue StandardError => e
      Rails.logger.error("Failed to save birth information: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end

  def create_encounter(patient_id, encounter_type, record)
    encounter_service = EncounterService.new
    encounter = encounter_service.create(
      type: EncounterType.find(encounter_type),
      patient: Patient.find(patient_id),
      program: Program.find(record[:program_id]),
      provider: record[:provider_id] ? Person.find(record[:provider_id]) : User.current.person,
      encounter_datetime: TimeUtils.retro_timestamp(record[:encounter_datetime]&.to_time || Time.now),
      location_id: record[:location_id] || Location.current.id
    )
    encounter.encounter_id
  end

  def save_obs(encounter_id:, observations:, location_id: nil)
    encounter = Encounter.find(encounter_id)
    observations.map do |archetype|
      archetype[:location_id] = location_id
      service = ObservationService.new
      service.create_observation(encounter, archetype.permit!)
    end
  end

  def save_vitals_data(patient_id, record)
    save_clinical_data(:vitals, patient_id, record)
  end

  def save_diagnosis_data(patient_id, record)
    save_clinical_data(:diagnosis, patient_id, record)
  end

def save_enrollment_data(patient_id, record)
  unsaved = record.dig(:NCDEnrollment, :unsaved)
  return unless unsaved.present? 

  {
    familyMedicalHistory: :familyMedicalHistory,
    patientRegistration: :patientRegistration,
    complications: :complications,
    hivStatusAtEnrollment: :hivStatusAtEnrollment,
    tbReception: :tbReception,
    medicalHistory: :medicalHistory
  }.each do |key, data_type|
    next unless unsaved[key].present?

    pass_save_data(data_type, unsaved[key], patient_id, record)
  end

  record[:NCDEnrollment][:unsaved] = {}
end


  def save_substance_abuse_data(patient_id, record)
    save_clinical_data(:substanceAbuse, patient_id, record)
  end

  def save_screening_data(patient_id, record)
    save_clinical_data(:screening, patient_id, record)
  end

  def save_lab_orders_data(patient_id, record)
    save_lab_order(:labOrders, patient_id, record)
  end
  def save_lab_results_data(patient_id, record)
    save_lab_results(:labResults, patient_id, record)
  end

  def save_vaccines(patient_id, record)
    orders = record.dig(:vaccineAdministration, :orders)
    return unless orders&.any?

    begin
      ActiveRecord::Base.transaction do
        orders.each do |order|
          encounter_id = create_encounter(patient_id, 25, record)

          obs = record.dig(:vaccineAdministration, :obs)&.find do |item|
            item[:value_text] == order[:drug_name]
          end

          AdministerVaccineService.administer_vaccine(encounter_id, [order], record[:program_id], [obs],
                                                      record[:provider_id], record[:location_id])
        end

        record[:vaccineAdministration][:obs] = []
        record[:vaccineAdministration][:orders] = []
      end
    rescue StandardError => e
      Rails.logger.error("Failed to save vaccines: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end

  def save_appointments(patient_id, record)
    return unless record[:appointments][:unsaved]&.any?

    encounter_id = create_encounter(patient_id, 7, record)

    save_obs(
      encounter_id: encounter_id,
      observations: record[:appointments][:unsaved],
      location_id: record[:location_id]
    )
    record[:appointments][:unsaved] = []
  end

  def send_sms(_patient_id, record)
    appointment_date = record.dig('sms', 'appointment_date')
    cell_phones = record.dig('sms', 'cell_phone')
    return unless appointment_date && cell_phones

    cell_phones.map do |phone|
      patient_details = { cell_phone: phone }
      enqueue_sms(appointment_date, patient_details, 'send_appointment')
    end
    record[:sms][:appointment_date] = ''
    record[:sms][:cell_phone] = []
  end

  def enqueue_sms(date, details, action)
    ImmunizationService::SendSmsService.perform_async(date, details, action)
  rescue StandardError => e
    "Failed to queue SMS: #{e.message}"
  end

  def void_vaccine(_patient_id, record)
    data = record.dig(:vaccineAdministration, :voided)
    return unless data&.any?

    begin
      ActiveRecord::Base.transaction do
        data.each do |item|
          order = Order.find(item[:order_id])

          # Perform the voiding inside the transaction
          order.void(item[:reason])
          Observation.where(order_id: order.id).each { |obs| obs.void(item[:reason]) }
        end

        # Clear the voided array only if all operations succeed
        record[:vaccineAdministration][:voided] = []
      end
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error("Order not found: #{e.message}")
      record[:vaccineAdministration][:voided] = []
    rescue StandardError => e
      Rails.logger.error("Error voiding vaccine: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end

  def save_notes_and_pharmalogical_notes(patient_id, record)
    save_observations_with_encounter(patient_id, record, {
      data_key: :notes,
      encounter_type: :notes,
      expected_type: 'NOTES',
      error_message: 'notes'
    })
  end

  def save_allergies(patient_id, record)
    save_observations_with_encounter(patient_id, record, {
      data_key: :allergies,
      encounter_type: :allergies,
      expected_type: 'MEDICAL HISTORY',
      error_message: 'allergies'
    })
  end

  def save_dispensation_data(patient_id, record)
    begin
      unsaved_data = record.dig(:dispensations, :unsaved)
      return unless unsaved_data&.any?

      # Permit the parameters for each dispensation record
      permitted_data = unsaved_data.map do |dispensation_params|
        dispensation_params.permit(
          :provider_id, 
          :program_id, 
          :patient_id,
          dispensations: [:drug_order_id, :date, :quantity]
        )
      end

      # Process each permitted dispensation
      permitted_data.each do |params|
        begin
          dispensations = params[:dispensations]
          program_id = params[:program_id]
          provider_id = params[:provider_id]

          # Find the program and provider
          program = Program.find(program_id) if program_id
          provider = provider_id ? Person.find(provider_id) : User.current.person

          # Create the dispensation
          DispensationService.create(program, dispensations, provider) if program && dispensations
        rescue ActiveRecord::RecordNotFound => e
          Rails.logger.error "Record not found while processing dispensation: #{e.message}"
          next  # Skip to next dispensation
        rescue StandardError => e
          Rails.logger.error "Error processing individual dispensation: #{e.message}"
          next  # Skip to next dispensation
        end
      end
    rescue StandardError => e
      Rails.logger.error "Error in save_dispensation_data: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      # raise e
    end
  end

  def save_medication_order(patient_id, record)
    orders = record.dig(:MedicationOrder, :unsaved)
    return unless orders&.any?
  
    begin
      ActiveRecord::Base.transaction do
        orders.each do |order|
          next unless order.key?(:NCD_Drug_Orders)
          drug_orders = order[:NCD_Drug_Orders]
          encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[:treatment])
          encounter_id = create_encounter(patient_id, encounter_type.id, record)
          encounter = Encounter.find(encounter_id)

          unless encounter.type.name == 'TREATMENT'
            Rails.logger.warn("Unexpected encounter type: #{encounter.type.name} for encounter ##{encounter.encounter_id}")
            next
          end
          
          DrugOrderService.create_drug_orders(encounter: , drug_orders:)
        end
      end
    rescue StandardError => e
      Rails.logger.error("Failed to create medication order: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise
    end
  end

  def save_outcome(patient_id, record)
    outcome = record.dig(:outCome, :unsaved)
    
    # Early return if outcome is nil or empty
    return unless outcome.present?
    
    begin
      # Convert to array if it's not already
      outcomes_array = outcome.is_a?(Array) ? outcome : [outcome]
      
      # Create observation service instance
      observation_service = ObservationService.new
      
      outcomes_array.each do |out_come|
        # Make sure out_come is not nil before proceeding
        next unless out_come.present?
        
        encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[:patient_outcome])
        encounter_id = create_encounter(patient_id, encounter_type.id, record)
        encounter = Encounter.find(encounter_id)
        
        unless encounter.type.name == 'PATIENT OUTCOME'
          Rails.logger.warn("Unexpected encounter type: #{encounter.type.name} for encounter ##{encounter.encounter_id}")
          next
        end
        
        # Convert ActionController::Parameters to a regular Hash
        if out_come.is_a?(ActionController::Parameters)
          out_come = out_come.permit!.to_h  # permit! allows all attributes
        end
        
        # Handle nested value_text if it's an ActionController::Parameters object
        if out_come[:value_text].is_a?(ActionController::Parameters)
          out_come[:value_text] = out_come[:value_text].permit!.to_h
          # Convert hash to JSON string for storage
          out_come[:value_text] = out_come[:value_text].to_json
        end
        
        # Add any missing required fields
        out_come[:person_id] = patient_id if out_come[:person_id].blank?
        out_come[:location_id] ||= User.current.location_id
        
        # Now pass the sanitized parameters to the service
        observation_service.create_observation(encounter, out_come)
      end
    rescue StandardError => e
      Rails.logger.error("Failed to create patient outcome: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise
    end
  end
  
  def save_lab_order(data_type, patient_id, record)
    unsaved_data = record.dig(:labOrders, :unsaved)
    return unless unsaved_data&.any?
    data_key = data_type.to_s.underscore.to_sym
    begin
      encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
      encounter_id = create_encounter(patient_id, encounter_type.id, record)
      orders = unsaved_data.map do |order_params|
        order_params = order_params.merge(encounter_id: encounter_id)
        Lab::OrdersService.order_test(order_params)
      end

      orders.each { |order| Lab::PushOrderJob.perform_later(order.fetch(:order_id)) }

      record[data_type][:unsaved] = []
    rescue StandardError => e
      log_error("Failed to save #{data_type} information", e)
    end

  end

  def save_lab_results(data_type, patient_id, record)
    unsaved_data = record.dig(:labOrders, :results)
    return unless unsaved_data&.any?
    data_key = data_type.to_s.underscore.to_sym
    
    begin
      encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
      encounter_id = create_encounter(patient_id, encounter_type.id, record)
      lab_results = unsaved_data[0].merge(encounter_id: encounter_id)
      Lab::ResultsService.create_results(lab_results[:test_id], lab_results)
      record[data_type][:results] = []
    rescue StandardError => e
      log_error("Failed to save #{data_type} information", e)
    end
    
  end

  def void_lab_order(patient_id, record)
    data = record.dig(:labOrders, :voided)
    return unless data&.any?
    data.map do |item|
      Lab::OrdersService.void_order(item[:orderId], item[:reason])
      Lab::VoidOrderJob.perform_later(item[:orderId])
    end
    record[:labOrders][:voided] = []
  end

  def save_clinical_data(data_type, patient_id, record)
    data_key = data_type.to_s.underscore.to_sym
    unsaved_data = record.dig(data_type, :unsaved)

    return unless unsaved_data&.any?
    if(data_type == :diagnosis && record.dig('program_id') == 32)
      unsaved_data.each do |item|
        if(item["value_coded"] == 6409 || item["value_coded"] == 6410)
          FhirService.sendConfirmedDiagnosisToMediator(patient_id,"Diabetes") 
        end
        if(item["value_coded"] == 903)
          FhirService.sendConfirmedDiagnosisToMediator(patient_id,"Hypertension") 
        end
      end
    end

    if save_observations(data_key, unsaved_data, patient_id, record)
      record[data_type][:unsaved] = []
    end
  end

  def pass_save_data(data_type, unsaved_data, patient_id, record)
    return unless unsaved_data&.any?

    data_key = data_type.to_s.underscore.to_sym
    save_observations(data_key, unsaved_data, patient_id, record)
  end

  private

  def save_all_observations(patient_id, record)
    data = record.dig(:observations)
    return unless data&.any?
  
    begin
      ActiveRecord::Base.transaction do
        data.each do |item|
          next unless item.present? && item[:status] == "unsaved" && item[:obs]&.any?
  
          encounter_type = EncounterType.find_by_name(item[:encounter_type])
          next unless encounter_type 
  
          encounter_id = create_encounter(patient_id, encounter_type.id, record)

          encounter = Encounter.find(encounter_id)
          item[:obs].map do |archetype|
            archetype[:location_id] = record[:location_id]
            service = ObservationService.new
            service.create_observation(encounter, archetype.permit!)
          end
        end
      end
    rescue StandardError => e
      Rails.logger.error("Error saving observations: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end

  def save_observations_with_encounter(patient_id, record, options)
    data = record.dig(options[:data_key], :unsaved)
    return unless data&.any?

    begin
      ActiveRecord::Base.transaction do
        data.each do |item|
          next unless item.present?

          encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[options[:encounter_type]])
          encounter_id = create_encounter(patient_id, encounter_type.id, record)
          encounter = Encounter.find(encounter_id)

          unless encounter.type.name == options[:expected_type]
            Rails.logger.warn("Unexpected encounter type: #{encounter.type.name} for encounter ##{encounter.encounter_id}")
            next
          end

          # Convert ActionController::Parameters to a regular Hash
          if item.is_a?(ActionController::Parameters)
            item = item.permit!.to_h
          end

          # Handle nested value_text if it's a complex object
          if item[:value_text].is_a?(ActionController::Parameters) || item[:value_text].is_a?(Hash)
            item[:value_text] = item[:value_text].to_json
          end

          # Add required fields
          item[:person_id] = patient_id if item[:person_id].blank?
          item[:location_id] ||= User.current.location_id

          # Create the observation with sanitized parameters
          observation_service.create_observation(encounter, item)
        end
      end
    rescue StandardError => e
      Rails.logger.error("Failed to save #{options[:error_message]}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end

  def save_observations(data_key, observations, patient_id, record)
    encounter_type_name = ENCOUNTER_TYPE_MAPPING[data_key]
    unless encounter_type_name
      log_error("No encounter type mapped for #{data_key}")
      return false
    end

    encounter_type = EncounterType.find_by_name(encounter_type_name)
    unless encounter_type
      log_error("EncounterType not found for #{encounter_type_name}")
      return false
    end

    begin
      encounter_id = create_encounter(patient_id, encounter_type.id, record)

      save_obs(
        encounter_id: encounter_id,
        observations: observations,
        location_id: record[:location_id]
      )
      true
    rescue StandardError => e
      log_error("Failed to save #{data_key} observations", e)
      false
    end
  end

  def log_error(message, error)
    Rails.logger.error("#{message}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))
  end

  def person_service
    PersonService.new
  end

  def observation_service
    ObservationService.new
  end
end
