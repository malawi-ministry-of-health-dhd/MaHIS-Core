# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module MahisUserImport
  class ApiClient
    class ApiError < StandardError
      attr_reader :status

      def initialize(message = nil, status: nil)
        @status = status
        super(message)
      end
    end

    attr_reader :base_url, :current_user

    def initialize(base_url)
      @base_url = base_url.to_s.sub(%r{/*\z}, '')
      @token = nil
      @current_user_payload = nil
      @current_user = nil
    end

    def login!(username:, password:)
      response = post('/api/v1/auth/login', { username: username, password: password }, authenticate: false)
      @token = response.dig('authorization', 'token')
      @current_user_payload = response.dig('authorization', 'user')

      unless @token.present? && @current_user_payload.present?
        raise ApiError, 'Target MaHIS login did not return an authorization token. Check password state or supervision requirements.'
      end

      true
    end

    def load_reference_data
      roles = fetch_roles
      programs = fetch_programs
      districts = fetch_districts
      locations = fetch_facilities
      @current_user = RemoteCurrentUser.new(user: @current_user_payload, locations: locations)

      {
        roles: roles,
        programs: programs,
        districts: districts,
        locations: locations,
        current_user: current_user
      }
    end

    def username_exists?(username)
      find_user_by_username(username).present?
    end

    def find_user_by_username(username)
      response = get('/api/v1/users', search_string: username, include_deactivated: true, paginate: false)
      matches = Array(response['results'] || response).select do |user|
        user['username'].to_s.casecmp?(username.to_s)
      end

      raise ApiError, "Target MaHIS returned multiple users for username #{username}" if matches.length > 1

      matches.first
    end

    def create_user!(attributes)
      response = post('/api/v1/users', {
        username: attributes[:username],
        password: attributes[:password],
        given_name: attributes[:given_name],
        family_name: attributes[:family_name],
        roles: attributes[:role_names],
        programs: attributes[:program_ids],
        location_id: attributes[:facility_id],
        phone: attributes[:phone],
        gender: attributes[:gender]
      })

      response['user'] || response
    end

    def upsert_user_property!(user_id:, property:, property_value:)
      post('/api/v1/user_properties', {
        user_id: user_id,
        property: property,
        property_value: property_value
      })
    end

    def upsert_current_user_property!(property:, property_value:)
      post('/api/v1/user_properties', {
        property: property,
        property_value: property_value
      })
    end

    def fetch_user_property(user_id:, property:)
      get('/api/v1/user_properties', user_id: user_id, property: property)
    end

    def clear_last_login_time!(user_id)
      post("/api/v1/users/#{user_id}/clear_last_login_time", {})
    end

    private

    def fetch_roles
      Array(get('/api/v1/roles', paginate: false)).map do |role|
        ReferenceRecord.new(role: role['role'])
      end
    end

    def fetch_programs
      Array(get('/api/v1/programs', paginate: false)).map do |program|
        ReferenceRecord.new(program_id: program['program_id'], name: program['name'])
      end
    end

    def fetch_districts
      Array(get('/api/v1/districts', paginate: false)).map do |district|
        ReferenceRecord.new(location_id: district['location_id'], name: district['name'])
      end
    end

    def fetch_facilities
      response = get('/api/v1/facilities', paginate: false)
      Array(response['data'] || response).map do |facility|
        ReferenceRecord.new(
          location_id: facility['location_id'],
          name: facility['name'],
          parent_location: facility['parent_location'],
          retired: facility['retired']
        )
      end
    end

    def get(path, params = {})
      uri = uri_for(path, params)
      request = Net::HTTP::Get.new(uri)
      perform(request, uri)
    end

    def post(path, body, authenticate: true)
      uri = uri_for(path)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request.body = body.to_json
      perform(request, uri, authenticate: authenticate)
    end

    def perform(request, uri, authenticate: true)
      request['Accept'] = 'application/json'
      request['Authorization'] = @token if authenticate && @token.present?

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end

      parsed = parse_response(response)
      return parsed if response.is_a?(Net::HTTPSuccess)

      raise ApiError.new(
        "Target MaHIS API #{request.method} #{uri.path} failed with HTTP #{response.code}: #{api_error_message(parsed)}",
        status: response.code.to_i
      )
    end

    def parse_response(response)
      return {} if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError
      { 'raw_response' => response.body.to_s[0, 500] }
    end

    def api_error_message(parsed)
      errors = parsed['errors'] || parsed['error'] || parsed['message'] || parsed['raw_response']
      Array(errors).join('; ')
    end

    def uri_for(path, params = {})
      uri = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params.present?
      uri
    end
  end
end
