# frozen_string_literal: true
module BuildPatientRecordService

  module PersonInformationBuilder
      def build(person, name, address, record)
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
          landmark: safe_get_attribute(record, 'Landmark Or Plot Number'),
          cell_phone_number: safe_get_attribute(record, 'Cell Phone Number'),
          occupation: safe_get_attribute(record, 'Occupation'),
          marital_status: safe_get_attribute(record, 'Civil Status'),
          religion: safe_get_attribute(record, 'Religion'),
          education_level: safe_get_attribute(record, 'EDUCATION LEVEL'),
        }
      end

      private

      def safe_get_attribute(item, name)
        return '' unless item&.person
        
        begin
          attribute = item.person.person_attributes.find { |attr| attr.type.name == name }
          attribute&.value || ''
        rescue StandardError => e
          Rails.logger.error("Error getting attribute '#{name}': #{e.message}")
          ''
        end
      end
    end
  end
