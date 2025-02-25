# frozen_string_literal: true

ENCOUNTER_TYPE_MAPPING = {
  vitals: 'VITALS',
  diagnosis: 'DIAGNOSIS',
  substance_abuse: 'ASSESSMENT',
  screening: 'SCREENING',
  lab_orders: 'LAB_ORDERS',
  medication_order:'TREATMENT'
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
      national_id: record.dig('otherPersonInformation', 'national_id'),
      birth_id: record.dig('otherPersonInformation', 'birth_id')
    }

    return if required_fields.values.any? { |value| value.nil? || value.to_s.empty? }
    return unless validate_id(ids[:national_id], ids[:birth_id])
    return unless (patient_id = save_person_information(record)[:patient_id])

    validate_id(ids[:national_id], ids[:birth_id])
    %i[
      create_guardian
      save_birthday_data
      save_vitals_data
      save_diagnosis_data
      save_substance_abuse_data
      save_screening_data
      save_lab_orders_data
      save_vaccines
      save_appointments
      send_sms
      void_vaccine
      save_medication_order
    ].each { |operation| send(operation, patient_id, record) }
    BuildPatientRecordService.build_patient_record(patient_id)
  end

  def save_person_information(record)
    if record[:personInformation] && record[:saveStatusPersonInformation] == 'pending'
      # Create person and get data
      person = create_person(record[:personInformation])
      patient = create_patient(person.person_id, record)
      identifier = BuildPatientRecordService.patient_identifier(patient, 3)
      patient_id = person.person_id

      create_ids(record[:otherPersonInformation], patient_id)
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
    if otherPersonInformation[:relationshipID].present?
      PatientIdentifierService.create(
        patient_id: patient_id,
        identifier: otherPersonInformation[:relationshipID],
        identifier_type: 28
      )
    end
    return unless otherPersonInformation[:birthID].present?

    PatientIdentifierService.create(
      patient_id: patient_id,
      identifier: otherPersonInformation[:birthID],
      identifier_type: 23
    )
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

  def validate_id(national_id, birth_id)
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

  def save_substance_abuse_data(patient_id, record)
    save_clinical_data(:substanceAbuse, patient_id, record)
  end

  def save_screening_data(patient_id, record)
    save_clinical_data(:screening, patient_id, record)
  end

  def save_lab_orders_data(patient_id, record)
    save_clinical_data(:labOrders, patient_id, record)
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

  def save_medication_order(patient_id, record)
    orders = record.dig(:MedicationOrder, :unsaved)
    return unless orders&.any?
  
    begin
      ActiveRecord::Base.transaction do
        orders.each do |order|
          next unless order.key?(:NCD_Drug_Orders)
          drug_orders = order[:NCD_Drug_Orders]
          encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[:medication_order])
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
  

  def save_clinical_data(data_type, patient_id, record)
    data_key = data_type.to_s.underscore.to_sym
    unsaved_data = record.dig(data_type, :unsaved)

    return unless unsaved_data&.any?

    begin
      encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
      encounter_id = create_encounter(patient_id, encounter_type.id, record)

      save_obs(
        encounter_id: encounter_id,
        observations: unsaved_data,
        location_id: record[:location_id]
      )

      record[data_type][:unsaved] = []
    rescue StandardError => e
      log_error("Failed to save #{data_type} information", e)
    end
  end

  private

  def log_error(message, error)
    Rails.logger.error("#{message}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))
  end

  def person_service
    PersonService.new
  end
end
