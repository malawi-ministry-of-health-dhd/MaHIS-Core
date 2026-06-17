# frozen_string_literal: true

module LoginResponseService
  LOGIN_PROPERTY_NAMES = %w[last_login_time last_password_updated].freeze
  FACILITY_LEVEL_ATTRIBUTE_NAMES = ['Facility Level', 'Facility Type'].freeze

  class << self
    def build(user, api_key, mark_login: true)
      facility_level = user ? facility_level_for_location(user.location_id) : nil
      return { authorization: api_key, facility_level: } unless user

      properties = login_properties(user.user_id)
      first_time_login = first_time_login_property?(properties['last_login_time'])
      mark_last_login!(user, properties['last_login_time']) if mark_login

      {
        authorization: api_key,
        facility_level:,
        first_time_login:,
        password_needs_update: password_needs_update_property?(properties['last_password_updated'])
      }
    end

    def first_time_login?(user)
      first_time_login_property?(login_properties(user.user_id)['last_login_time'])
    end

    def password_needs_update?(user_id)
      password_needs_update_property?(login_properties(user_id)['last_password_updated'])
    end

    private

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
