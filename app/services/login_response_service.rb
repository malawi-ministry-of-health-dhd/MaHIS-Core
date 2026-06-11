# frozen_string_literal: true

module LoginResponseService
  class << self
    def build(user, api_key, mark_login: true)
      facility_level = user ? facility_level_for_location(user.location_id) : nil
      return { authorization: api_key, facility_level: } unless user

      first_time_login = first_time_login?(user)
      mark_last_login!(user) if mark_login

      {
        authorization: api_key,
        facility_level:,
        first_time_login:,
        password_needs_update: password_needs_update?(user.user_id)
      }
    end

    def first_time_login?(user)
      last_login_property = UserProperty.find_by(
        property: 'last_login_time',
        user_id: user.user_id
      )

      last_login_property.nil? || last_login_property.property_value.blank?
    end

    def password_needs_update?(user_id)
      last_password_property = UserProperty.find_by(
        property: 'last_password_updated',
        user_id:
      )

      return false if last_password_property.nil? || last_password_property.property_value.blank?

      last_updated = Time.parse(last_password_property.property_value)
      Time.current >= last_updated + 90.days
    rescue ArgumentError
      false
    end

    private

    def mark_last_login!(user)
      property = UserProperty.find_or_initialize_by(
        property: 'last_login_time',
        user_id: user.user_id
      )

      property.property_value = Time.current.iso8601
      property.save
    end

    def facility_level_for_location(location_id)
      return nil if location_id.blank?

      facility_level = location_attribute_value(location_id, 'Facility Level')
      return facility_level if facility_level.present?

      facility_type = location_attribute_value(location_id, 'Facility Type')
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

    def location_attribute_value(location_id, attribute_type_name)
      attribute_type_id = LocationAttributeType.where(name: attribute_type_name).pick(:location_attribute_type_id)
      return nil if attribute_type_id.blank?

      LocationAttribute.where(location_id:, attribute_type_id:)
                       .where(voided: [nil, false, 0])
                       .order(location_attribute_id: :desc)
                       .pick(:value_reference)
    end
  end
end
