# frozen_string_literal: true

module MahisUserImport
  class RemoteUserCreator
    def initialize(api_client)
      @api_client = api_client
    end

    def create!(attributes)
      user = @api_client.create_user!(attributes)
      user_id = user['user_id'] || user[:user_id]
      raise ApiClient::ApiError, 'Target MaHIS user creation response did not include user_id' if user_id.blank?

      assign_user_properties!(user_id, attributes)
      user
    end

    def assign_user_properties!(user_id, attributes)
      properties = user_properties(attributes)

      begin
        upsert_user_properties!(user_id, properties)
      rescue ApiClient::ApiError => e
        raise unless e.status == 404

        upsert_properties_as_target_user!(user_id, attributes, properties)
      end
    end

    private

    def user_properties(attributes)
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

      properties.compact
    end

    def upsert_user_properties!(user_id, properties)
      properties.compact.each do |property, property_value|
        @api_client.upsert_user_property!(user_id: user_id, property: property, property_value: property_value.to_s)
      end
    end

    def upsert_properties_as_target_user!(user_id, attributes, properties)
      previous_last_login = previous_last_login_value(user_id)
      target_client = ApiClient.new(@api_client.base_url)
      target_client.login!(username: attributes[:username], password: attributes[:password])

      properties.each do |property, property_value|
        target_client.upsert_current_user_property!(property: property, property_value: property_value.to_s)
      end

      restore_last_login!(target_client, user_id, previous_last_login)
    end

    def previous_last_login_value(user_id)
      property = @api_client.fetch_user_property(user_id: user_id, property: 'last_login_time')
      property['property_value'] if property.present?
    end

    def restore_last_login!(target_client, user_id, previous_last_login)
      if previous_last_login.present?
        target_client.upsert_current_user_property!(property: 'last_login_time', property_value: previous_last_login)
      else
        @api_client.clear_last_login_time!(user_id)
      end
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
