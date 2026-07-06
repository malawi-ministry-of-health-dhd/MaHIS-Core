# frozen_string_literal: true

module MahisUserImport
  class RowValidator
    DEFAULT_PASSWORD = 'Change@2026'
    LIST_SEPARATOR = /[,;|]/
    PROTECTED_ROLES = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser'].freeze
    GLOBAL_ONLY_ROLES = ['Global Superuser', 'District Superuser'].freeze

    ValidationResult = Struct.new(:row_number, :attributes, :errors, keyword_init: true) do
      def valid?
        errors.empty?
      end

      def username
        attributes[:username]
      end
    end

    def initialize(roles: nil, programs: nil, districts: nil, locations: nil, current_user: nil)
      @roles = roles || Role.all.to_a
      @programs = programs || Program.all.to_a
      @districts = districts || District.all.to_a
      @locations = locations || Location.unscoped.where(retired: [0, false]).to_a
      @current_user = current_user || User.current
    end

    def call(row)
      @row = row
      @data = row.data.with_indifferent_access
      @errors = []

      attributes = extract_attributes
      validate_required_attributes(attributes)
      validate_username(attributes[:username])
      validate_password(attributes[:password])
      resolve_references(attributes)
      validate_facility_district(attributes)
      validate_admin_location_scope(attributes)
      validate_admin_role_permissions(attributes)

      ValidationResult.new(row_number: row.number, attributes: attributes, errors: @errors)
    end

    private

    def extract_attributes
      given_name, family_name, full_name = extract_names
      username_source = value(:username).presence || full_name

      {
        row_number: @row.number,
        full_name: full_name,
        given_name: given_name,
        family_name: family_name,
        username: UsernameGenerator.generate(username_source),
        gender: normalize_gender(value(:gender)),
        phone: value(:phone_number),
        role_inputs: parse_list(value(:role)),
        program_inputs: parse_list(value(:program)),
        district_input: value(:district),
        facility_input: value(:facility),
        password: value(:password).presence || DEFAULT_PASSWORD,
        waiting_list_access: normalize_waiting_list_access(value(:waiting_list_access)),
        activities: normalize_list_value(value(:activities)),
        opd_activities: normalize_list_value(value(:opd_activities)),
        aetc_activities: normalize_list_value(value(:aetc_activities)),
        ncd_activities: normalize_list_value(value(:ncd_activities)),
        opd_waiting_list: normalize_list_value(value(:opd_waiting_list))
      }
    end

    def extract_names
      full_name = value(:full_name)
      given_name = value(:first_name)
      family_name = value(:last_name)

      if full_name.present? && (given_name.blank? || family_name.blank?)
        parsed_given_name, parsed_family_name = split_full_name(full_name)
        given_name = parsed_given_name if given_name.blank?
        family_name = parsed_family_name if family_name.blank?
      end

      full_name = [given_name, family_name].compact.join(' ').presence if full_name.blank?
      [given_name, family_name, full_name]
    end

    def split_full_name(full_name)
      parts = full_name.to_s.squish.split(/\s+/)
      return [parts.first, nil] if parts.length < 2

      [parts.first, parts[1..].join(' ')]
    end

    def resolve_references(attributes)
      attributes[:role_names] = resolve_roles(attributes[:role_inputs])
      attributes[:programs] = resolve_programs(attributes[:program_inputs])
      attributes[:program_ids] = attributes[:programs].map(&:program_id)
      attributes[:program_names] = attributes[:programs].map(&:name)
      attributes[:district] = resolve_district(attributes[:district_input])
      attributes[:facility] = resolve_facility(attributes[:facility_input], attributes[:district])
      attributes[:district_id] = attributes[:district]&.location_id
      attributes[:district_name] = attributes[:district]&.name
      attributes[:facility_id] = attributes[:facility]&.location_id
      attributes[:facility_name] = attributes[:facility]&.name
      ActivityDefaults.apply(attributes)
    end

    def validate_required_attributes(attributes)
      add_error('full_name or first_name/last_name is required') if attributes[:full_name].blank?
      add_error('first_name is required') if attributes[:given_name].blank?
      add_error('last_name is required') if attributes[:family_name].blank?
      add_error('gender is required') if attributes[:gender].blank?
      add_error('phone_number is required') if attributes[:phone].blank?
      add_error('role is required') if attributes[:role_inputs].empty?
      add_error('program is required') if attributes[:program_inputs].empty?
      add_error('district is required') if attributes[:district_input].blank?
      add_error('facility is required') if attributes[:facility_input].blank?
    end

    def validate_username(username)
      if username.blank?
        add_error('username is required and could not be generated from full_name')
        return
      end

      add_error('username must not contain spaces') if username.match?(/\s/)
      add_error('username must be 50 characters or fewer') if username.length > 50
    end

    def validate_password(password)
      add_error('password must be at least 8 characters') if password.length < 8
      add_error('password must contain at least one capital letter') unless password.match?(/[A-Z]/)
      add_error('password must contain at least one number') unless password.match?(/\d/)
      add_error('password must contain at least one special character') unless password.match?(/[^A-Za-z0-9]/)
      add_error('password must not contain spaces') if password.match?(/\s/)
    end

    def validate_facility_district(attributes)
      facility = attributes[:facility]
      district = attributes[:district]
      return if facility.blank? || district.blank? || facility.parent_location.blank?
      return if facility.parent_location.to_i == district.location_id.to_i

      parent = @locations.find { |location| location.location_id.to_i == facility.parent_location.to_i }
      add_error(
        "facility '#{facility.name}' is under '#{parent&.name || facility.parent_location}', not '#{district.name}'"
      )
    end

    def validate_admin_location_scope(attributes)
      current_user = @current_user
      facility = attributes[:facility]
      return if current_user.blank? || facility.blank?
      return if current_user.global_superuser?

      return if current_user.managed_location_ids&.include?(facility.location_id.to_i)

      add_error("configured admin is not authorised to create users at facility '#{facility.name}'")
    end

    def validate_admin_role_permissions(attributes)
      current_user = @current_user
      return if current_user.blank?

      attributes[:role_names].each do |role_name|
        next unless protected_role?(role_name)
        next if current_user.global_superuser?

        if current_user.is_superuser?
          next unless GLOBAL_ONLY_ROLES.any? { |role| role.casecmp(role_name).zero? }
        end

        add_error("configured admin is not authorised to assign the '#{role_name}' role")
      end
    end

    def resolve_roles(role_inputs)
      role_inputs.filter_map do |role_input|
        matches = matching_records(@roles, :role, role_input)
        if matches.empty?
          add_error("role '#{role_input}' was not found")
          next
        end

        matches.first.role
      end.uniq
    end

    def resolve_programs(program_inputs)
      program_inputs.filter_map do |program_input|
        matches = matching_records(@programs, :name, program_input, id_method: :program_id, program: true)
        if matches.empty?
          add_error("program '#{program_input}' was not found")
          next
        end

        program = matches.first
        if program.program_id.to_i <= 0
          add_error("program '#{program_input}' has an invalid program_id #{program.program_id}")
          next
        end

        program
      end.uniq(&:program_id)
    end

    def resolve_district(district_input)
      return nil if district_input.blank?

      matches = matching_records(@districts, :name, district_input, id_method: :location_id, district: true)
      if matches.empty?
        matches = matching_records(@locations, :name, district_input, id_method: :location_id, district: true)
      end

      case matches.length
      when 0
        add_error("district '#{district_input}' was not found")
        nil
      when 1
        matches.first
      else
        add_error("district '#{district_input}' matched multiple locations: #{location_ids(matches)}")
        nil
      end
    end

    def resolve_facility(facility_input, district)
      return nil if facility_input.blank?

      matches = matching_records(@locations, :name, facility_input, id_method: :location_id)
      if district && matches.length > 1
        matches = matches.select { |location| location.parent_location.to_i == district.location_id.to_i }
      end

      case matches.length
      when 0
        add_error("facility '#{facility_input}' was not found")
        nil
      when 1
        matches.first
      else
        add_error("facility '#{facility_input}' matched multiple locations: #{location_ids(matches)}")
        nil
      end
    end

    def matching_records(records, attribute, value, id_method: nil, district: false, program: false)
      return [] if value.blank?

      if id_method && value.to_s.match?(/\A\d+\z/)
        return records.select { |record| record.public_send(id_method).to_i == value.to_i }
      end

      lookup_keys = comparable_keys(value, district: district, program: program)
      exact_matches = records.select do |record|
        (comparable_keys(record.public_send(attribute), district: district, program: program) & lookup_keys).any?
      end
      return exact_matches if exact_matches.any?

      records.select do |record|
        record_keys = comparable_keys(record.public_send(attribute), district: district, program: program)
        record_keys.any? do |record_key|
          lookup_keys.any? { |lookup_key| record_key.include?(lookup_key) || lookup_key.include?(record_key) }
        end
      end
    end

    def protected_role?(role_name)
      PROTECTED_ROLES.any? { |role| role.casecmp(role_name).zero? }
    end

    def comparable_keys(value, district: false, program: false)
      text = I18n.transliterate(value.to_s).downcase.squish
      keys = [text, text.gsub(/[^a-z0-9]/, '')]

      if district
        keys << text.gsub(/\bdistrict\b/, '').squish
        keys << text.gsub(/\bdistrict\b/, '').gsub(/[^a-z0-9]/, '')
      end

      if program
        keys << text.gsub(/\bprogram\b/, '').squish
        keys << text.gsub(/\bprogram\b/, '').gsub(/[^a-z0-9]/, '')
      end

      keys.reject(&:blank?).uniq
    end

    def normalize_gender(gender)
      case gender.to_s.strip.downcase
      when 'male', 'm'
        'M'
      when 'female', 'f'
        'F'
      else
        gender.to_s.strip.presence
      end
    end

    def normalize_waiting_list_access(value)
      case value.to_s.strip.downcase
      when ''
        nil
      when 'yes', 'y', 'true', '1'
        'true'
      when 'no', 'n', 'false', '0'
        'false'
      else
        value.to_s.strip
      end
    end

    def normalize_list_value(value)
      parse_list(value).join(',').presence
    end

    def parse_list(value)
      value.to_s.split(LIST_SEPARATOR).map(&:strip).reject(&:blank?)
    end

    def value(key)
      @data[key].to_s.strip.presence
    end

    def location_ids(locations)
      locations.map { |location| "#{location.name}(#{location.location_id})" }.join(', ')
    end

    def add_error(message)
      @errors << message
    end
  end
end
