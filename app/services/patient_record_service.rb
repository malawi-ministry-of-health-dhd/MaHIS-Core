# frozen_string_literal: true

module PatientRecordService
  class << self 
    include ModelUtils

    def build_patient_record(patient_id)
      record =Patient.find(patient_id)
      {
        patientID: patient_id,
        ID: patient_identifier(record, 3),
        NcdID: patient_identifier(record, 31),
        personInformation: {
            given_name: record.person.names[0].given_name,
            middle_name: record.person.names[0].middle_name,
            family_name: record.person.names[0].family_name,
            gender: record.person.gender,
            birthdate: record.person.birthdate,
            birthdate_estimated: "false",
            home_region: "",
            home_district: record.person.addresses[0].address2,
            home_traditional_authority: record.person.addresses[0].county_district,
            home_village: record.person.addresses[0].neighborhood_cell,
            current_region: "",
            current_district: record.person.addresses[0].state_province,
            current_traditional_authority: record.person.addresses[0].township_division,
            current_village: record.person.addresses[0].city_village,
            country: record.person.addresses[0].country,
            landmark: "",
            cell_phone_number: get_attribute(record, "Cell Phone Number"),
            occupation: get_attribute(record, "Occupation"),
            marital_status: get_attribute(record, "Civil Status"),
            religion: "",
            education_level: get_attribute(record, "EDUCATION LEVEL"),
        },
        guardianInformation: {
            saved: get_guardians(patient_id),
            unsaved: [],
        },
        birthRegistration: extract_observations(patient_id,5,[11764, 11759, 3753], "value_text"),
        otherPersonInformation: {
            national_id: "",
            birth_id: "",
            relationshipID: "",
        },
        vitals: {
            saved: extract_observations(patient_id,6,[5089, 5088, 5087, 5086, 5085, 5090, 5092, 5242, 2137], "value_numeric"),
            unsaved: [],
        },
        vaccineSchedule: ImmunizationService::VaccineScheduleService.vaccine_schedule(Person.find(patient_id)),
        vaccineAdministration: {
            orders: [],
            obs: [],
            voided: [],
        },
        appointments: {
            saved: [],
            unsaved: [],
        },
        saveStatusPersonInformation: "complete",
        saveStatusGuardianInformation: "complete",
        saveStatusBirthRegistration: "complete",
        date_created: ""
      }
    end
    def get_attribute(item, name)
      attribute = item.person.person_attributes.find { |attr| attr.type.name == name }
      attribute&.value
    end
    def patient_identifier(identifiers, identifier_type_id)
      if identifiers
        identifiers.patient_identifiers
                   .select { |identifier| identifier.identifier_type == identifier_type_id }
                   .map(&:identifier)
                   .join(", ")
      else
        ""
      end
    end
    def get_guardians(patient_id)
      relationships_service = PersonRelationshipService.new Person.find(patient_id)
      relationships = relationships_service.find_relationships("")
      return [] unless relationships.is_a?(Enumerable) && relationships.any?
    
      relationships.map do |relationship|
        person = relationship.relation
        name = person.names&.first
        address = person.addresses&.first
    
        # Helper function to safely get person attribute value
        get_attribute_value = lambda do |attributes, attribute_name|
          attribute = attributes&.find { |attr| attr.type.name == attribute_name }
          attribute ? attribute.value : ""
        end
    
        {
          given_name: name&.given_name || "",
          middle_name: name&.middle_name || "",
          family_name: name&.family_name || "",
          gender: person&.gender || "",
          birthdate: person&.birthdate || "",
          birthdate_estimated: person&.birthdate_estimated&.to_s || "",
    
          home_region: address&.region || "",
          home_district: address&.county_district || "",
          home_traditional_authority: address&.township_division || "",
          home_village: address&.city_village || "",
    
          current_region: address&.region || "",
          current_district: address&.county_district || "",
          current_traditional_authority: address&.township_division || "",
          current_village: address&.city_village || "",
    
          landmark: get_attribute_value.call(person&.person_attributes, "Landmark Or Plot Number"),
          cell_phone_number: get_attribute_value.call(person&.person_attributes, "Cell Phone Number"),
          national_id: "",
    
          relationship_id: relationship.id.to_s || "",
          relationship_type: {
            a_is_to_b: relationship.type&.a_is_to_b || "",
            b_is_to_a: relationship.type&.b_is_to_a || "",
            relationship_type_id: relationship.type&.id&.to_s || "",
          },
        }
      end
    end
    
    def extract_observations(patient_id,encounter_type,concept_ids, obs_type)
      encounters = Encounter.where(patient_id: patient_id, encounter_type: encounter_type)
      encounters.flat_map do |encounter|
        encounter.observations
                 .select { |observation| concept_ids.include?(observation.concept_id) }
                 .map do |observation|
                    if(obs_type == "value_text")
                      {
                        concept_id: observation.concept_id,
                        obs_datetime: observation.obs_datetime,
                        value_text: observation.value_text
                      }
                    elsif(obs_type == "value_numeric")
                        {
                          concept_id: observation.concept_id,
                          obs_datetime: observation.obs_datetime,
                          value_numeric: observation.value_numeric,
                          obs_id: observation.obs_id,
                        }
                    end
                 end
      end
    end


    def create_patient_record(record)
      person_info = record[:other_person_information]
      return if validate_id(
        national_id: person_info[:national_id],
        birth_id: person_info[:birth_id]
      )
      
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
      if record.person_information && record.save_status_person_information == "pending"
        begin
          # Create person and get data
          data = create_person(record.person_information)
          patient = create_patient(data.person_id, record)
          identifier = patient_identifier(patient, 3)
          patient_id = data.person_id
  
  
          # Execute concurrent operations
          threads = []
          threads << Thread.new { create_ids(record.other_person_information, patient_id) }
          threads << Thread.new { enroll_program(patient_id, record) }
          threads << Thread.new { create_encounter(patient_id, 5,record)}
          threads.each(&:join)
  
          return { patient_id: patient_id, id: identifier }
        rescue StandardError => e
          Rails.logger.error("Failed to save person information: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
        end
      end
  
      { patient_id: record.patient_id, id: record.id }
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


    def create_ids(other_person_information, patient_id)
      if other_person_information[:national_id].present?
        PatientIdentifierService.create(
          patient_id: patient_id,
          identifier: other_person_information[:national_id],
          identifier_type: 28
        )
      end
      if other_person_information[:birth_id].present?
        PatientIdentifierService.create(
          patient_id: patient_id,
          identifier: other_person_information[:birth_id],
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

    def create_registration_encounter(patient_id)
      # Implementation for creating registration encounter
    end

    
    def validate_id(national_id:, birth_id:)
      validate_identifier(national_id, type: :national) && 
      validate_identifier(birth_id, type: :birth)
    end
  
    def validate_identifier(id, type:)
      return true if id.empty?
      
      identifier_type_id = type == :national ? 28 : 23
      !identifier_exists?(identifier_type_id, id)
    end
  
    def identifier_exists?(type_id, id)
      return false unless type_id
      
      identifier_type = PatientIdentifierType.find(type_id)
      PatientService.new.find_patients_by_identifier(id, identifier_type).any?
    end




    def save_person_information(record)
      
    end
    def create_guardian(patient_id, record)
      return unless record[:save_status_guardian_information] == "pending"
  
      if guardian_info_complete?(record)
        begin
          guardian_data = create_person(record[:guardian_information][:unsaved][0])
          guardian_id = guardian_data[:person_id]
          
          create_relation(
            guardian_id: guardian_id,
            relationship_id: record[:other_person_information][:relationship_id]
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
  
    private
  
    def guardian_info_complete?(record)
      guardian = record.dig(:guardian_information, :unsaved, 0)
      relationship_id = record.dig(:other_person_information, :relationship_id)
  
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

    end
    def send_sms(patient_id, record)

    end
    def void_vaccine(patient_id, record)

    end
    def person_service
      PersonService.new
    end
  end
end
