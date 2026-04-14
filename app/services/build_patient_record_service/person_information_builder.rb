# frozen_string_literal: true
module BuildPatientRecordService

  module PersonInformationBuilder
      def build(person, name, address, record)
        attribute_values = person_attribute_values(record&.person)

        {
          given_name: name&.given_name || '',
          middle_name: name&.middle_name || '',
          family_name: name&.family_name || '',
          gender: person&.gender || '',
          birthdate: person&.birthdate&.to_s || '',
          birthdate_estimated: 'false',
          home_region: '',
          home_district: address&.address2 || '',
          home_traditional_authority: address&.county_district || '',
          home_village: address&.neighborhood_cell || '',
          current_region: '',
          current_district: address&.state_province || '',
          current_traditional_authority: address&.township_division || '',
          current_village: address&.city_village || '',
          country: address&.country || '',
          landmark: attribute_values['Landmark or plot number'] || '',
          cell_phone_number: attribute_values['Cell phone number'] || '',
          occupation: attribute_values['Occupation'] || '',
          transportation: attribute_values['Transportation'] || attribute_values['Mode of transport'] || '',
          marital_status: attribute_values['Civil status'] || '',
          religion: attribute_values['Religion'] || '',
          education_level: attribute_values['Education level'] || '',
        }
      end

      private

      def person_attribute_values(person)
        return {} unless person

        attributes = if person.association(:person_attributes).loaded?
                       person.person_attributes
                     else
                       person.person_attributes.includes(:type)
                     end

        attributes.each_with_object({}) do |attribute, values|
          type_name = attribute.type&.name
          next if type_name.blank?

          values[type_name] ||= attribute.value
        end
      rescue StandardError => e
        Rails.logger.error("Error loading person attributes for person #{person&.person_id}: #{e.message}")
        {}
      end
    end
  end
