# frozen_string_literal: true

module LoginResponseService
  LOGIN_PROPERTY_NAMES = %w[last_login_time last_password_updated].freeze
  FACILITY_LEVEL_ATTRIBUTE_NAMES = ['Facility Level', 'Facility Type'].freeze
  SUPERVISION_SESSION_PROPERTY = 'current_supervision_session'
  SUPERVISION_REQUIREMENTS = {
    'Student Nurse' => {
      supervision_type: 'nurse',
      supervisor_role: 'Nurse',
      excluded_roles: ['Student Nurse', 'Intern Nurse']
    },
    'Student Clinician' => {
      supervision_type: 'clinician',
      supervisor_role: 'Clinician',
      excluded_roles: ['Student Clinician', 'Intern Clinician']
    },
    'Intern Clinician' => {
      supervision_type: 'clinician',
      supervisor_role: 'Clinician',
      excluded_roles: ['Student Clinician', 'Intern Clinician']
    }
  }.freeze

  class << self
    def build(user, api_key, mark_login: true, require_supervision: true)
      facility_level = user ? facility_level_for_location(user.location_id) : nil
      return { authorization: api_key, facility_level: } unless user

      properties = login_properties(user.user_id)
      first_time_login = first_time_login_property?(properties['last_login_time'])
      password_needs_update = password_needs_update_property?(properties['last_password_updated'])

      if require_supervision && api_key.present? && !first_time_login && !password_needs_update
        requirement = supervision_requirement(user)
        if requirement && !supervision_confirmed_today?(user, requirement)
          return supervision_required_response(user, requirement, facility_level)
        end
      end

      mark_last_login!(user, properties['last_login_time']) if mark_login

      {
        authorization: api_key,
        facility_level:,
        first_time_login:,
        password_needs_update:
      }.tap do |response|
        supervision_session = current_supervision_session(user)
        response[:supervision_session] = supervision_session if supervision_session
      end
    end

    def supervision_requirement(user)
      role_names(user).each do |role_name|
        requirement = SUPERVISION_REQUIREMENTS[role_name]
        return requirement.merge(trainee_role: role_name) if requirement
      end

      nil
    end

    def supervisors_for(user, requirement)
      User.includes(:person, :roles)
          .joins(:roles)
          .where(location_id: user.location_id)
          .where(role: { role: requirement[:supervisor_role] })
          .where.not(user_id: user.user_id)
          .distinct
          .select { |candidate| valid_supervisor?(user, candidate, requirement) }
          .map { |candidate| supervisor_payload(candidate, requirement[:supervisor_role]) }
    end

    def valid_supervisor?(trainee, supervisor, requirement)
      return false unless supervisor&.active?
      return false if supervisor.user_id.to_i == trainee.user_id.to_i
      return false if supervisor.location_id.to_i != trainee.location_id.to_i

      supervisor_roles = role_names(supervisor)
      supervisor_roles.include?(requirement[:supervisor_role]) &&
        (supervisor_roles & requirement[:excluded_roles]).empty?
    end

    def record_supervision!(trainee, supervisor, requirement)
      payload = {
        trainee_user_id: trainee.user_id,
        trainee_role: requirement[:trainee_role],
        supervisor_user_id: supervisor.user_id,
        supervisor_name: supervisor.name,
        supervisor_role: requirement[:supervisor_role],
        supervision_type: requirement[:supervision_type],
        location_id: trainee.location_id,
        started_at: Time.current.iso8601
      }

      property = UserProperty.find_or_initialize_by(
        property: SUPERVISION_SESSION_PROPERTY,
        user_id: trainee.user_id
      )
      property.user = trainee
      property.property_value = payload.to_json
      property.save!
      payload
    end

    def supervision_confirmed_today?(user, requirement = nil)
      session = current_supervision_session(user)
      return false unless session
      return false if requirement && session['trainee_role'] != requirement[:trainee_role]

      true
    end

    def current_supervision_session(user)
      property = UserProperty.find_by(
        property: SUPERVISION_SESSION_PROPERTY,
        user_id: user.user_id
      )
      return nil if property&.property_value.blank?

      session = JSON.parse(property.property_value)
      return nil unless Time.zone.parse(session['started_at']).to_date == Time.current.to_date

      session
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end

    def first_time_login?(user)
      first_time_login_property?(login_properties(user.user_id)['last_login_time'])
    end

    def password_needs_update?(user_id)
      password_needs_update_property?(login_properties(user_id)['last_password_updated'])
    end

    private

    def supervision_required_response(user, requirement, facility_level)
      {
        action: 'supervision_required',
        supervision_required: true,
        trainee_user_id: user.user_id,
        trainee_role: requirement[:trainee_role],
        supervision_type: requirement[:supervision_type],
        supervisor_role: requirement[:supervisor_role],
        facility_level:,
        supervisors: supervisors_for(user, requirement)
      }
    end

    def supervisor_payload(user, supervisor_role)
      {
        user_id: user.user_id,
        name: user.name,
        username: user.username,
        role: supervisor_role,
        location_id: user.location_id
      }
    end

    def role_names(user)
      if user.association(:roles).loaded?
        user.roles.map(&:role)
      else
        user.roles.pluck(:role)
      end
    end

    def login_properties(user_id)
      UserProperty.where(user_id:, property: LOGIN_PROPERTY_NAMES).index_by(&:property)
    end

    def first_time_login_property?(property)
      property.nil? || property.property_value.blank?
    end

    def password_needs_update_property?(property)
      return false if property.nil? || property.property_value.blank?

      last_updated = Time.parse(property.property_value)
      Time.current >= last_updated + 90.days
    rescue ArgumentError
      false
    end

    def mark_last_login!(user, property = nil)
      property ||= UserProperty.new(property: 'last_login_time', user_id: user.user_id)

      property.property_value = Time.current.iso8601
      property.save
    end

    def facility_level_for_location(location_id)
      return nil if location_id.blank?

      attribute_type_ids = LocationAttributeType.where(name: FACILITY_LEVEL_ATTRIBUTE_NAMES)
                                                .pluck(:name, :location_attribute_type_id)
                                                .to_h
      attributes = latest_location_attributes(location_id, attribute_type_ids.values)

      facility_level = attributes[attribute_type_ids['Facility Level']]
      return facility_level if facility_level.present?

      facility_type = attributes[attribute_type_ids['Facility Type']]
      return nil if facility_type.blank?

      case facility_type.to_s.strip.downcase
      when 'health centre', 'health center'
        'Primary'
      when 'district hospital'
        'Secondary'
      when 'central hospital'
        'Tertiary'
      end
    end

    def latest_location_attributes(location_id, attribute_type_ids)
      return {} if attribute_type_ids.blank?

      LocationAttribute.where(location_id:, attribute_type_id: attribute_type_ids)
                       .where(voided: [nil, false, 0])
                       .order(location_attribute_id: :desc)
                       .pluck(:attribute_type_id, :value_reference)
                       .each_with_object({}) do |(attribute_type_id, value_reference), attributes|
                         attributes[attribute_type_id] ||= value_reference
                       end
    end
  end
end
