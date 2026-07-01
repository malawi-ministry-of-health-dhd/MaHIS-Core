# frozen_string_literal: true

module MahisUserImport
  class ImportRunner
    CONFIRMATION_PHRASE = 'CREATE USERS'

    def initialize(environment:, dry_run:, input: $stdin, output: $stdout)
      @environment = environment.to_s
      @dry_run = dry_run
      @input = input
      @output = output
      @summary = empty_summary
      @seen_usernames = {}
    end

    def call
      config = ConfigLoader.new.load(@environment)
      rows = ExcelReader.new(config.users_file_path).read
      @summary[:total_rows] = rows.length

      @logger = ImportLogger.new(output: @output)
      log_start(config, rows.length)

      api_client = authenticate_admin!(config)
      confirm!(config, rows.length) if config.require_confirmation && !@dry_run

      process_rows(rows, api_client)
      @logger.summary(@summary)
      @summary
    ensure
      @logger&.close
    end

    private

    def process_rows(rows, api_client)
      reference_data = api_client.load_reference_data
      validator = RowValidator.new(**reference_data)
      creator = RemoteUserCreator.new(api_client)

      rows.each do |row|
        validation = validator.call(row)

        unless validation.valid?
          log_invalid_row(validation)
          next
        end

        same_file_duplicate_reason = same_file_duplicate_reason(validation.username)
        if same_file_duplicate_reason
          @summary[:skipped_duplicates] += 1
          @logger.row(
            row_number: row.number,
            status: 'skipped',
            username: validation.username,
            messages: [same_file_duplicate_reason]
          )
          next
        end

        existing_user = api_client.find_user_by_username(validation.username)

        if @dry_run
          if existing_user
            log_dry_run_existing_user(validation, existing_user)
            next
          end

          @summary[:dry_run_valid_rows] += 1
          @seen_usernames[validation.username] = true
          @logger.row(
            row_number: row.number,
            status: 'dry-run valid',
            username: validation.username,
            messages: dry_run_messages(validation.attributes)
          )
          next
        end

        if existing_user
          update_existing_user_properties!(creator, validation, existing_user)
          next
        end

        create_user!(creator, validation)
      end
    end

    def create_user!(creator, validation)
      user = creator.create!(validation.attributes)
      @summary[:created_users] += 1
      @seen_usernames[validation.username] = true
      @logger.row(
        row_number: validation.row_number,
        status: 'created',
        username: validation.username,
        messages: [
          "user_id=#{user_id_from(user)}",
          "facility=#{validation.attributes[:facility_name]}",
          "roles=#{validation.attributes[:role_names].join('|')}",
          "programs=#{validation.attributes[:program_names].join('|')}"
        ]
      )
    rescue StandardError => e
      @summary[:failed_rows] += 1
      @logger.row(
        row_number: validation.row_number,
        status: 'failed',
        username: validation.username,
        messages: [e.message]
      )
    end

    def update_existing_user_properties!(creator, validation, user)
      validate_existing_user_facility!(user, validation.attributes)
      user_id = user_id_from(user)
      creator.assign_user_properties!(user_id, validation.attributes)
      @summary[:updated_existing_users] += 1
      @seen_usernames[validation.username] = true
      @logger.row(
        row_number: validation.row_number,
        status: 'updated existing',
        username: validation.username,
        messages: [
          "user_id=#{user_id}",
          "facility=#{validation.attributes[:facility_name]}",
          'properties=updated'
        ]
      )
    rescue StandardError => e
      @summary[:failed_rows] += 1
      @logger.row(
        row_number: validation.row_number,
        status: 'failed',
        username: validation.username,
        messages: [e.message]
      )
    end

    def log_dry_run_existing_user(validation, user)
      validate_existing_user_facility!(user, validation.attributes)
      @summary[:dry_run_valid_rows] += 1
      @seen_usernames[validation.username] = true
      @logger.row(
        row_number: validation.row_number,
        status: 'dry-run existing',
        username: validation.username,
        messages: [
          "user_id=#{user_id_from(user)}",
          "would_update_properties_at_facility=#{validation.attributes[:facility_name]}"
        ]
      )
    rescue StandardError => e
      @summary[:dry_run_invalid_rows] += 1
      @logger.row(
        row_number: validation.row_number,
        status: 'dry-run invalid',
        username: validation.username,
        messages: [e.message]
      )
    end

    def log_invalid_row(validation)
      if @dry_run
        @summary[:dry_run_invalid_rows] += 1
        status = 'dry-run invalid'
      else
        @summary[:failed_rows] += 1
        status = 'failed'
      end

      @logger.row(
        row_number: validation.row_number,
        status: status,
        username: validation.username,
        messages: validation.errors
      )
    end

    def same_file_duplicate_reason(username)
      return 'duplicate username already appears earlier in this Excel file' if @seen_usernames[username]

      nil
    end

    def user_id_from(user)
      return user.user_id if user.respond_to?(:user_id)

      user['user_id'] || user[:user_id]
    end

    def validate_existing_user_facility!(user, attributes)
      existing_facility_id = existing_user_facility_id(user)
      return if existing_facility_id.blank? || existing_facility_id.to_i == attributes[:facility_id].to_i

      raise ApiClient::ApiError,
            "duplicate username already exists at facility_id=#{existing_facility_id}; expected facility_id=#{attributes[:facility_id]}"
    end

    def existing_user_facility_id(user)
      user['location_id'] ||
        user.dig('location', 'location_id') ||
        user.dig('current_location', 'location_id') ||
        user.dig('location', :location_id) ||
        user.dig(:current_location, :location_id)
    end

    def dry_run_messages(attributes)
      [
        "would_create_at_facility=#{attributes[:facility_name]}",
        "roles=#{attributes[:role_names].join('|')}",
        "programs=#{attributes[:program_names].join('|')}"
      ]
    end

    def authenticate_admin!(config)
      api_client = ApiClient.new(config.target_url)
      api_client.login!(username: config.admin_username, password: config.admin_password)
      api_client
    end

    def confirm!(config, total_rows)
      @output.puts
      @output.puts 'Manual confirmation required before creating users:'
      @output.puts "  environment: #{@environment}"
      @output.puts "  target_url: #{config.target_url}"
      @output.puts "  users_file: #{config.users_file}"
      @output.puts "  total_rows: #{total_rows}"
      @output.puts "  dry_run: #{@dry_run}"
      @output.print "Type #{CONFIRMATION_PHRASE} to continue: "

      answer = @input.gets&.strip
      return if answer == CONFIRMATION_PHRASE

      raise 'Import cancelled: confirmation phrase was not entered'
    end

    def log_start(config, total_rows)
      @logger.info(
        'starting MaHIS user import ' \
        "environment=#{@environment} " \
        "target_url=#{config.target_url} " \
        "users_file=#{config.users_file} " \
        "total_rows=#{total_rows} " \
        "dry_run=#{@dry_run}"
      )
    end

    def empty_summary
      {
        total_rows: 0,
        created_users: 0,
        updated_existing_users: 0,
        skipped_duplicates: 0,
        failed_rows: 0,
        dry_run_valid_rows: 0,
        dry_run_invalid_rows: 0
      }
    end
  end
end
