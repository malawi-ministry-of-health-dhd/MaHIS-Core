# frozen_string_literal: true

module Api
  module V1
    class UsersController < ApplicationController

      
      DEFAULT_ROLENAME = 'clerk'
      include PasswordPolicy

      skip_before_action :authenticate, only: %i[login reset_password]

      def index
        filters = params.permit(:role, :search_string, :include_deactivated, :location_id, location_ids: []).to_hash.transform_keys(&:to_sym)
        query = service.find_users(**filters) 

        render json: {
          count: query[1],
          results: paginate(query[0])
        }, status: :ok
      end

      def show
        render json: find_user(params[:id]), status: :ok
      end

      def update_username
        new_username, = params.require(%i[new_username])
        target_user = find_user(params[:id] || params[:user_id])  # uses find_user which unscopes
        return unless validate_username(new_username)
        updated = UserService.update_username(target_user, new_username)
        render json: { message: ['username updated successfully'], user: updated }
      end

      def create
        create_params = params.require(%i[username password given_name family_name roles location_id])
        username, password, given_name, family_name, roles, location_id = create_params
        programs = params[:programs]
        villages = params[:villages]
        phone = params[:phone]
        gender = params[:gender]

        return unless validate_roles(roles) & validate_username(username) & validate_location(location_id)
        return unless validate_role_permissions(roles)

        # added this as a seperate return to prevent multiple redirects in case more than one validation fails
        return if programs && !validate_programs(programs)

        # added this as a seperate return to prevent multiple redirects in case more than one validation fails
        return if programs && !validate_programs_existance(programs)

        user = UserService.create_user(
          username:, password:, given_name:,
          family_name:, roles:, programs:, location_id:, villages:, phone:, gender:
        )

        if user.errors.empty?
          render json: { user: }, status: :created
        else
          render json: { errors: user.errors }, status: :bad_request
        end
      rescue UserService::UserCreateError => e
        render json: { errors: e }, status: :internal_server_error
      end

      def update
        update_params = params.permit :password, :given_name, :family_name, :must_append_roles, :location_id,
                                      roles: [], programs: []

        # Force programs through since permit can silently drop integer arrays
        update_params[:programs] = UserService.normalize_program_ids(params[:programs]) if params.key?(:programs)

        # Reject unknown/retired program ids up-front so the update never deletes
        # existing assignments only to silently fail to recreate them.
        return if params.key?(:programs) && !validate_programs_existance(update_params[:programs])

        return unless validate_roles(update_params[:roles])
        return unless validate_role_permissions(update_params[:roles])

        if update_params[:location_id] && !validate_location(update_params[:location_id])
          return
        end

        user = UserService.update_user find_user(params[:id]), update_params

        if user.errors.empty?
          update_last_password_property(user.id, update_params[:password])
          render json: user, status: :ok
        else
          render json: user.errors, status: :bad_request
        end
      end

      def reset_password
        code = params[:code]

        render json: { authorization: UserService.reset_password(code:) },
                status: :ok
      end

      def login
        login_params, error = required_params required: %i[username password]
        return render json: login_params, status: :bad_request if error

        user = UserService.authenticate_credentials(login_params[:username], login_params[:password])
        
        if user.nil?
          render json: { errors: ['Invalid user or password'] }, status: :unauthorized
        else
          password_response = LoginResponseService.build(user, nil, mark_login: false)
          if password_change_required?(password_response)
            return render json: LoginResponseService.build(user, UserService.new_authentication_token(user))
          end

          if extra_security_login_enabled?(user)
            if PasskeyAuthenticationService.required_for?(user)
              passkey_challenge = PasskeyAuthenticationService.authentication_options(user)
              render json: {
                passkey_authentication_required: true,
                passkey_session: passkey_challenge[:session_token],
                public_key: passkey_challenge[:options]
              }, status: :accepted
            else
              passkey_challenge = PasskeyAuthenticationService.registration_options(user)
              render json: {
                passkey_registration_required: true,
                passkey_session: passkey_challenge[:session_token],
                public_key: passkey_challenge[:options]
              }, status: :accepted
            end
          else
            render json: LoginResponseService.build(user, UserService.new_authentication_token(user)), status: :ok
          end
        end
      end

      def check_first_time_login
        user_id = params[:user_id] || User.current.user_id
        
        last_login_property = UserProperty.find_by(
          property: 'last_login_time',
          user_id: user_id
        )
        
        # Check both existence and that the value is not blank
        is_first_time = last_login_property.nil? || last_login_property.property_value.blank?
        
        render json: {
          user_id: user_id,
          first_time_login: is_first_time,
          has_logged_in_before: !is_first_time,
          last_login_time: last_login_property&.property_value,
          message: is_first_time ? 'User has never logged in before' : 'User has logged in before'
        }, status: :ok
      rescue StandardError => e
        render json: { errors: [e.message] }, status: :internal_server_error
      end

      def clear_last_login_time
        user_id = params[:user_id] || User.current.user_id

        last_login_property = UserProperty.find_by(
          property: 'last_login_time',
          user_id: user_id
        )
        
        if last_login_property
          last_login_property.destroy
          render json: { message: 'Last login time cleared successfully' }, status: :ok
        else
          render json: { message: 'No last login time found to clear' }, status: :ok
        end
      rescue StandardError => e
        render json: { errors: [e.message] }, status: :internal_server_error
      end

      def destroy
        if User.find(params[:id]).void('No reason provided')
          render status: :no_content
        else
          render json: { errors: ['Failed to void user'] }, status: :internal_server_error
        end
      end

      # GET
      def activate
        if UserService.activate_user(user)
          render json: { message: ['User activated'], user: }
        else
          render json: { errors: user.errors }
        end
      end

      # Deactivates user
      def deactivate
        if UserService.deactivate_user(user)
          render json: { message: ['User de-activated'], user: }
        else
          render json: { errors: user.errors }
        end
      end

      def update_user_villages
        update_params = params.permit user_village_ids: []
        user_villages = UserService.update_user_villages(user, update_params[:user_village_ids])
        render json: { villages: user_villages }, status: :ok
      rescue => e
        render json: { errors: [e.message] }, status: :internal_server_error
      end

      def get_user_villages
        villages = UserService.get_user_villages(user).where(retired: 0)
        render json: { villages: villages }, status: :ok
      rescue StandardError => e
        render json: { errors: [e.message] }, status: :internal_server_error
      end

      def check_username_exist
        username_param = params.permit(:username)
        if username_param[:username].blank?
          render json: { errors: ['Username parameter is required'] }, status: :bad_request
          return
        end
        
        exists = UserService.check_user(username_param[:username])
        render json: { exists: exists }, status: :ok
      rescue StandardError => e
        render json: { errors: [e.message] }, status: :internal_server_error
      end

      private

      def login_response(user, api_key)
        LoginResponseService.build(user, api_key)
      end

      def password_change_required?(login_response)
        login_response[:first_time_login] || login_response[:password_needs_update]
      end

      def extra_security_login_enabled?(user)
        property = UserProperty.find_by(user_id: user.user_id, property: 'extra_security_login')
        property&.property_value&.downcase == 'true'
      end

      def validate_roles(roles)
        if roles && !roles.respond_to?(:each)
          render json: ['`roles` must be an array'], status: :bad_request
          return false
        end

        true
      end

      PROTECTED_ROLES = %w[Superuser Global\ Superuser District\ Superuser Facility\ Superuser].freeze
      # Only a Global Superuser may grant these roles
      GLOBAL_ONLY_ROLES = ['Global Superuser', 'District Superuser'].freeze

      def validate_role_permissions(roles)
        return true if roles.blank?

        roles.each do |role|
          next unless PROTECTED_ROLES.any? { |pr| pr.casecmp(role.to_s).zero? }

          # Global Superusers may assign any protected role
          next if User.current.global_superuser?

          # Plain Superusers may assign any protected role except Global Superuser
          if User.current.is_superuser?
            next unless GLOBAL_ONLY_ROLES.any? { |gr| gr.casecmp(role.to_s).zero? }
          end

          render json: { errors: ["You are not authorised to assign the '#{role}' role"] }, status: :forbidden
          return false
        end

        true
      end

      def validate_username(username)
        if UserService.check_user(username)
          errors = ['User already exists']
          render json: { errors: }, status: :conflict
          return false
        end

        true
      end

      def user
        find_user(params[:id] || params[:user_id])
      end

      private

      def find_user(id)
        users = User.with_serialization_preloads

        if User.current.global_superuser?
          users.unscope(where: :location_id).find(id)
        elsif User.current.district_superuser?
          users.unscope(where: :location_id).where(location_id: User.current.managed_location_ids).find(id)
        else
          users.find(id)
        end
      end

      # validate user programs here
      def validate_programs(programs)
        if programs && !programs.respond_to?(:each)
          render json: ['`programs` must be an array'], status: :bad_request
          return false
        end

        true
      end

      # validate location here
      def validate_location(location_id)
        return true if User.current.global_superuser?

        unless User.current.managed_location_ids.include?(location_id.to_i)
          render json: ["Location ID #{location_id} is out of your authorized scope"], status: :forbidden
          return false
        end

        true
      end

      # validate program
      def validate_programs_existance(programs)
        UserService.normalize_program_ids(programs).each do |program_id|
          next if Program.find_by(program_id:)

          errors = ['All Programs must exists']
          render json: { errors: }, status: :conflict
          return false
        end
      end

      def update_last_password_property(user_id, password)
        return unless password.present?
        
        property = UserProperty.find_or_initialize_by(
          property: 'last_password_updated',
          user_id: user_id
        )
        
        property.property_value = Time.current.to_s
        property.save
      end

      def password_needs_update?(user_id)
        last_password_property = UserProperty.find_by(
          property: 'last_password_updated',
          user_id: user_id
        )
        
        # Return false if no property exists or property_value is blank
        return false if last_password_property.nil? || last_password_property.property_value.blank?
        
        # Parse the timestamp and check if 90 days have elapsed
        last_updated = Time.parse(last_password_property.property_value)
        Time.current >= last_updated + 90.days
      rescue ArgumentError
        # Return false if timestamp can't be parsed
        false
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

        LocationAttribute.where(location_id: location_id, attribute_type_id: attribute_type_id)
                         .where(voided: [nil, false, 0])
                         .order(location_attribute_id: :desc)
                         .pick(:value_reference)
      end

      def service
        UserService
      end
    end
  end
end
