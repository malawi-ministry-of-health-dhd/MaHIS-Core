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
            nationalID: "",
            birthID: "",
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
    
   
  end
end
