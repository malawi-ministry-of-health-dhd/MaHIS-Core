# frozen_string_literal: true

module BuildPatientRecordService
  class << self
    include ModelUtils
    def build_patient_record(patient_id)
      record = Patient.find(patient_id)
      {
        patientID: patient_id,
        ID: patient_identifier(record, 3),
        NcdID: patient_identifier(record, 31),
        program_id: '',
        provider_id: '',
        location_id: '',
        encounter_datetime: '',
        personInformation: {
          given_name: record.person.names[0].given_name,
          middle_name: record.person.names[0].middle_name,
          family_name: record.person.names[0].family_name,
          gender: record.person.gender,
          birthdate: record.person.birthdate,
          birthdate_estimated: 'false',
          home_region: '',
          home_district: record.person.addresses[0].address2,
          home_traditional_authority: record.person.addresses[0].county_district,
          home_village: record.person.addresses[0].neighborhood_cell,
          current_region: '',
          current_district: record.person.addresses[0].state_province,
          current_traditional_authority: record.person.addresses[0].township_division,
          current_village: record.person.addresses[0].city_village,
          country: record.person.addresses[0].country,
          landmark: '',
          cell_phone_number: get_attribute(record, 'Cell Phone Number'),
          occupation: get_attribute(record, 'Occupation'),
          marital_status: get_attribute(record, 'Civil Status'),
          religion: '',
          education_level: get_attribute(record, 'EDUCATION LEVEL')
        },
        guardianInformation: {
          saved: get_guardians(patient_id),
          unsaved: []
        },
        birthRegistration: extract_observations(patient_id, EncounterType.find_by_name('REGISTRATION').id),
        otherPersonInformation: {
          national_id: '',
          birth_id: '',
          relationshipID: ''
        },
        vitals: {
          saved: extract_observations(patient_id, EncounterType.find_by_name('VITALS').id),
          unsaved: []
        },
        vaccineSchedule: ImmunizationService::VaccineScheduleService.vaccine_schedule(Person.find(patient_id)),
        vaccineAdministration: {
          orders: [],
          obs: [],
          voided: []
        },
        appointments: {
          saved: [],
          unsaved: []
        },
        diagnosis: {
          saved: extract_observations(patient_id, EncounterType.find_by_name('DIAGNOSIS').id),
          unsaved: []
        },
        screening: {
          saved: [extract_observations(patient_id, EncounterType.find_by_name('SCREENING').id, nil, true) +
            extract_observations(patient_id, EncounterType.find_by_name('SCREENING').id,
                                 { concept_id: concept_name_to_id('CVD') })].flatten,
          unsaved: []
        },
        substanceAbuse: {
          saved: extract_observations(patient_id, EncounterType.find_by_name('ASSESSMENT').id),
          unsaved: []
        },
        MedicationOrder: {
          saved: get_client_drug_orders(patient_id),
          unsaved: []
        },
        saveStatusPersonInformation: '',
        saveStatusGuardianInformation: '',
        saveStatusBirthRegistration: ''
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
                   .join(', ')
      else
        ''
      end
    end

    def get_guardians(patient_id)
      relationships_service = PersonRelationshipService.new Person.find(patient_id)
      relationships = relationships_service.find_relationships('')
      return [] unless relationships.is_a?(Enumerable) && relationships.any?

      relationships.map do |relationship|
        person = relationship.relation
        name = person.names&.first
        address = person.addresses&.first

        # Helper function to safely get person attribute value
        get_attribute_value = lambda do |attributes, attribute_name|
          attribute = attributes&.find { |attr| attr.type.name == attribute_name }
          attribute ? attribute.value : ''
        end

        {
          given_name: name&.given_name || '',
          middle_name: name&.middle_name || '',
          family_name: name&.family_name || '',
          gender: person&.gender || '',
          birthdate: person&.birthdate || '',
          birthdate_estimated: person&.birthdate_estimated&.to_s || '',

          home_region: address&.region || '',
          home_district: address&.county_district || '',
          home_traditional_authority: address&.township_division || '',
          home_village: address&.city_village || '',

          current_region: address&.region || '',
          current_district: address&.county_district || '',
          current_traditional_authority: address&.township_division || '',
          current_village: address&.city_village || '',

          landmark: get_attribute_value.call(person&.person_attributes, 'Landmark Or Plot Number'),
          cell_phone_number: get_attribute_value.call(person&.person_attributes, 'Cell Phone Number'),
          national_id: '',

          relationship_id: relationship.id.to_s || '',
          relationship_type: {
            a_is_to_b: relationship.type&.a_is_to_b || '',
            b_is_to_a: relationship.type&.b_is_to_a || '',
            relationship_type_id: relationship.type&.id&.to_s || ''
          }
        }
      end
    end

    def extract_observations(patient_id, encounter_type, value_filters = nil, has_children = nil)
      encounters = Encounter.where(patient_id: patient_id, encounter_type: encounter_type)

      encounters.flat_map do |encounter|
        encounter.observations
                 .select do |observation|
                   if value_filters
                     matches_filters?(observation, value_filters)
                   else
                     !has_children || observation.children.length.positive?
                   end
                 end
                 .map do |observation|
          children = if observation.children.length.positive?
                       observation.children.map do |child|
                         {
                           concept_id: child.concept_id,
                           concept_name: concept_id_to_name(child.concept_id),
                           obs_datetime: child.obs_datetime,
                           obs_id: child.obs_id,
                           children: child.children,
                           value_coded: child.value_coded,
                           value_text: child.value_text,
                           value_numeric: child.value_numeric
                         }
                       end
                     else
                       []
                     end
          {
            concept_id: observation.concept_id,
            concept_name: concept_id_to_name(observation.concept_id),
            obs_datetime: observation.obs_datetime,
            obs_id: observation.obs_id,
            children: children,
            value_coded: observation.value_coded,
            value_text: observation.value_text,
            value_numeric: observation.value_numeric
          }
        end
      end
    end

    def get_client_drug_orders(patient_id)
      begin
        return [] if patient_id.nil? || patient_id.to_s.strip.empty?
        
        begin
          results = DrugOrderService.fetch_all_patient_drug_orders(patient_id)
          return results unless results.empty?
        rescue => e
          Rails.logger.error("Inner error fetching drug orders for patient #{patient_id}: #{e.message}")
        end
        
        []
      rescue => e
        Rails.logger.error("Outer error fetching drug orders for patient #{patient_id}: #{e.message}")
        []
      end
    end

    def matches_filters?(observation, filters)
      return true if filters.empty?

      filters.any? do |field, value|
        observation.send(field) == value
      end
    end
  end
end