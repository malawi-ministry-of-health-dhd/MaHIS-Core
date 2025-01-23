# frozen_string_literal: true

module SavePatientRecordService
  class << self 
    include ModelUtils

    def create_patient_record(record)
      national_id=record.dig("otherPersonInformation", "national_id")
      birth_id=record.dig("otherPersonInformation", "birth_id")
      return unless validate_id( national_id,birth_id)
      
      data = save_person_information(record)
      patient_id = data[:patient_id]
      return unless patient_id
    
      create_guardian(patient_id, record)
      save_birthday_data(patient_id, record)
      save_vitals_data(patient_id, record)
      save_vaccines(patient_id, record)
      save_appointments(patient_id, record)
      send_sms(patient_id, record)
      void_vaccine(patient_id, record)
    end

    def save_person_information(record)
      puts(record)
      if record[:personInformation] && record[:saveStatusPersonInformation] == "pending"
        begin
          # Create person and get data
          data = create_person(record[:personInformation])
          puts("🚀 ~ data:", data)
          patient = create_patient(data[:person_id], record)
          identifier = patient_identifier(patient, 3)
          patient_id = data[:person_id]
  
  
          # Execute concurrent operations
          threads = []
          threads << Thread.new { create_ids(record[:otherPersonInformation], patient_id) }
          threads << Thread.new { enroll_program(patient_id, record) }
          threads << Thread.new { create_encounter(patient_id, 5,record)}
          threads.each(&:join)
  
          return { patient_id: patient_id, id: identifier }
        rescue StandardError => e
          Rails.logger.error("Failed to save person information: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
        end
      end
  
      { patient_id: record[:patient_id], id: record[:id] }
    end

    def create_registration_encounter(patient_id,record) 
      encounter_service =EncounterService.new
      encounter_service.create(
          type: EncounterType.find(5),
          patient: Patient.find(patient_id),
          program: Program.find(record.program_id),
          provider: record.provider_id ? Person.find(record.provider_id) : User.current.person,
          encounter_datetime: TimeUtils.retro_timestamp(record.encounter_datetime&.to_time || Time.now)
        )
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
      program = Program.find(record.program_id)

      service = PatientService.new
      service.create_patient(program, person, "", record.ID)
    end

    def create_ids(otherPersonInformation, patient_id)
      if otherPersonInformation[:national_id].present?
        PatientIdentifierService.create(
          patient_id: patient_id,
          identifier: otherPersonInformation[:national_id],
          identifier_type: 28
        )
      end
      if otherPersonInformation[:birth_id].present?
        PatientIdentifierService.create(
          patient_id: patient_id,
          identifier: otherPersonInformation[:birth_id],
          identifier_type: 23
        )
      end
    end

    def enroll_program( patient_id, record)
      if PatientProgram.where(program_id: record.program_id, patient_id: patient_id)
        .exists?
        render json: { errors: ['Patient already enrolled in program'] },
        status: :conflict
        return
      end
  
      new_patient_program = PatientProgram.create(
        program_id: record.program_id,
        date_enrolled: record.date_enrolled || Time.now,
        location_id: record.location_id || Location.current.id,
        patient_id: patient_id
      )

      if new_patient_program.errors.empty?
        render json: new_patient_program, status: :created
      else
        render json: new_patient_program.errors, status: :bad_request
      end
    end


    
    def validate_id(national_id, birth_id)
      validate_identifier(national_id, type: :national) && 
      validate_identifier(birth_id, type: :birth)
    end
  
    def validate_identifier(id, type:)
      return true if (id.nil? || id.empty?)
      
      identifier_type_id = type == :national ? 28 : 23
      !identifier_exists?(identifier_type_id, id)
    end
  
    def identifier_exists?(type_id, id)
      return false unless type_id
      
      identifier_type = PatientIdentifierType.find(type_id)
      PatientService.new.find_patients_by_identifier(id, identifier_type).any?
    end

    def create_guardian(patient_id, record)
      return unless record[:save_status_guardian_information] == "pending"
  
      if guardian_info_complete?(record)
        begin
          guardian_data = create_person(record[:guardian_information][:unsaved][0])
          guardian_id = guardian_data[:person_id]
          
          create_relation(
            guardian_id: guardian_id,
            relationship_id: record[:otherPersonInformation][:relationship_id]
          )
       
        rescue StandardError => e
          Rails.logger.error("Failed to save guardian information: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
        end
      else
        update_save_status(
          record,
          save_status_guardian_information: "Not recorded"
        )
      end
    end
  
  
    def guardian_info_complete?(record)
      guardian = record.dig(:guardian_information, :unsaved, 0)
      relationship_id = record.dig(:otherPersonInformation, :relationship_id)
  
      guardian&.dig(:given_name).present? &&
        guardian&.dig(:family_name).present? &&
        relationship_id.present?
    end
  
    def create_relation( guardian_id:, relationship_type_id:)
      begin
        relationship_type = RelationshipType.find relationship_type_id
        person = Person.find guardian_id
      rescue ActiveRecord::RecordNotFound => e
        return render json: { errors: e.message }, status: :bad_request
      end

      service.create_relationship person, relationship_type
    end
  
    def save_birthday_data(patient_id, record)
      return unless record[:save_status_birth_registration] == "pending"
  
      if record[:birth_registration].present? && record[:birth_registration].any?
        begin
          encounter_id = create_encounter(patient_id, 5,record)
          save_obs(
            encounter_id: encounter_id,
            observations: record[:birth_registration]
          )
        rescue StandardError => e
          Rails.logger.error("Failed to save birth information: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
        end
      else
        
      end
    end
  
  
    def create_encounter(patient_id, encounter_type, record)
      encounter_service =EncounterService.new
      encounter_service.create(
          type: EncounterType.find(encounter_type),
          patient: Patient.find(patient_id),
          program: Program.find(record.program_id),
          provider: record.provider_id ? Person.find(record.provider_id) : User.current.person,
          encounter_datetime: TimeUtils.retro_timestamp(record.encounter_datetime&.to_time || Time.now)
        )
    end
  
    def save_obs(encounter_id:, observations:)
      encounter = Encounter.find(encounter_id)
      observations.map do |archetype|
        service =ObservationService.new
        service.create_observation(encounter, archetype)
      end
    end
    def save_vitals_data(patient_id, record)
      return unless record.dig(:vitals, :unsaved)&.any?
  
      begin
        encounter_id = create_encounter(patient_id, 6, record)
        save_obs(
          encounter_id: encounter_id,
          observations: record[:vitals][:unsaved]
        )
      rescue StandardError => e
        Rails.logger.error("Failed to save vitals information: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
      end
    end
    def save_vaccines(patient_id, record)
      orders = record.dig(:vaccine_administration, :orders)
      return unless orders&.any?
  
      threads = orders.map do |order|
        Thread.new do
          begin
            encounter_id = create_encounter(patient_id, 25)
            obs = record.dig(:vaccine_administration, :obs)&.find do |item|
              item[:value_text] == order[:drug_name]
            end
            AdministerVaccineService.administer_vaccine(encounter_id, [order], record.program_id, [obs])
          rescue StandardError => e
            Rails.logger.error("Failed to save vaccine order: #{e.message}")
            Rails.logger.error(e.backtrace.join("\n"))
          end
        end
      end
  
      threads.each(&:join)
    end
    def save_appointments(patient_id, record)
      if record&.appointments&.unsaved&.length&.positive?
        encounter_id = create_encounter(patient_id, 7)
        save_obs({
          encounter_id: encounter_id,
          observations: record&.appointments&.unsaved
        })
      end
    end
    def send_sms(patient_id, record)
      if record&.sms&.appointment_date
        patient_details = {cell_phone:record.sms }
        enqueue_sms(record.sms.appointment_date, patient_details,'send_appointment')
      end
    end
    def enqueue_sms(date, details, action)
      ImmunizationService::SendSmsService.perform_async(date, details, action)
    rescue => e
      "Failed to queue SMS: #{e.message}"
    end

    def void_vaccine(patient_id, record)
      data = record.vaccine_administration.voided
      if data&.length&.positive?
        data.map do |item|
          begin
            order = Order.find(item.order_id)
            ActiveRecord::Base.transaction do
              order.void(item.reason)
              Observation.where(order_id: order.id).each { |obs| obs.void(item.reason)}
            end
            render json: order, status: :no_content
    
          rescue ActiveRecord::RecordNotFound
            render json: { errors: "Order ##{item.order_id} not found" }, status: :not_found
          rescue => error
            puts error
          end
        end
      end
    end
    def person_service
      PersonService.new
    end
  end
end
