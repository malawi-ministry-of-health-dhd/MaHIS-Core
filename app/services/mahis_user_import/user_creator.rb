# frozen_string_literal: true

module MahisUserImport
  class UserCreator
    class CreationError < StandardError; end

    def create!(attributes)
      original_location = Location.current
      facility = Location.unscoped.find(attributes[:facility_id])
      Location.current = facility

      ActiveRecord::Base.transaction do
        user = UserService.create_user(
          username: attributes[:username],
          password: attributes[:password],
          given_name: attributes[:given_name],
          family_name: attributes[:family_name],
          roles: attributes[:role_names],
          programs: attributes[:program_ids],
          location_id: attributes[:facility_id],
          villages: [],
          phone: attributes[:phone],
          gender: attributes[:gender]
        )

        raise CreationError, user.errors.full_messages.join(', ') if user.errors.any?

        ensure_assignments!(user, attributes)
        assign_user_properties!(user, attributes)
        user
      end
    ensure
      Location.current = original_location
    end

    private

    def ensure_assignments!(user, attributes)
      assigned_roles = UserRole.where(user_id: user.user_id).pluck(:role)
      missing_roles = attributes[:role_names] - assigned_roles
      raise CreationError, "Failed to assign roles: #{missing_roles.join(', ')}" if missing_roles.any?

      assigned_programs = UserProgram.where(user_id: user.user_id).pluck(:program_id).map(&:to_i)
      missing_programs = attributes[:program_ids].map(&:to_i) - assigned_programs
      raise CreationError, "Failed to assign programs: #{missing_programs.join(', ')}" if missing_programs.any?
    end

    def assign_user_properties!(user, attributes)
      properties = {
        'last_password_updated' => Time.current.iso8601,
        'district' => attributes[:district_name],
        'district_id' => attributes[:district_id],
        'facility' => attributes[:facility_name],
        'facility_id' => attributes[:facility_id]
      }

      if attributes[:waiting_list_access].present?
        properties['waiting_list_access'] = attributes[:waiting_list_access]
        properties['OPD_waiting_list_access'] = attributes[:waiting_list_access] if opd_program?(attributes)
      end

      if attributes[:activities].present?
        properties['Activities'] = attributes[:activities]
        properties['OPD_activities'] = attributes[:activities] if opd_program?(attributes)
        properties['AETC_activities'] = attributes[:activities] if aetc_program?(attributes)
      end

      properties.compact.each do |name, value|
        upsert_user_property!(user, name, value)
      end
    end

    def upsert_user_property!(user, name, value)
      property = UserProperty.find_or_initialize_by(user_id: user.user_id, property: name)
      property.user = user
      property.property_value = value.to_s
      property.save!
    end

    def opd_program?(attributes)
      program_name_match?(attributes, /opd/i)
    end

    def aetc_program?(attributes)
      program_name_match?(attributes, /aetc/i)
    end

    def program_name_match?(attributes, pattern)
      attributes[:program_names].any? { |name| name.match?(pattern) }
    end
  end
end
