# frozen_string_literal: true

module Api
  module V1
    class RolesController < ApplicationController
      before_action :authorize_role_management,
                    only: %i[create update destroy add_privilege remove_privilege]

      def index
        roles_query = Role.includes(:privileges)

        if Role.location_scoped?
          roles_query = roles_query.where(location_id: params[:location_id])
                                   .or(roles_query.where(location_id: nil))
        end

        roles = params[:paginate] == 'true' ? paginate(roles_query) : roles_query.order(:role)
        render json: serialize_roles(roles)
      end

      def show
        role = Role.includes(:privileges).find(params[:id])
        render json: serialize_roles([role]).first
      end

      def create
        role = Role.create!(role_params)
        render json: role, status: :created
      end

      def update
        role = Role.find(params[:id])
        role.update!(role_params)
        render json: role
      end

      def destroy
        role = Role.find(params[:id])
        role.destroy!
        head :no_content
      end

      def sync_superuser_privileges
        return unless authorize_superuser_sync

        superuser_result = Role.sync_superuser_privileges!(location_id: sync_location_id)
        standard_result  = Role.sync_standard_privileges!
        Sync::RolesPermissionsSyncJob.perform_async

        render json: {
          message: 'Privileges synced successfully',
          superuser: superuser_result,
          standard: standard_result
        }, status: :ok
      rescue StandardError => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      end

      def add_privilege
        role_name = params[:id]
        privilege_name = params[:privilege]

        # Verify role and privilege exist
        Role.find(role_name)
        Privilege.find(privilege_name)

        # Check if the privilege is already assigned to the role
        unless RolePrivilege.exists?(role: role_name, privilege: privilege_name)
          # Use new + save to bypass association validation issues with composite keys
          role_privilege = RolePrivilege.new
          role_privilege.write_attribute(:role, role_name)
          role_privilege.write_attribute(:privilege, privilege_name)
          role_privilege.save!
        end

        render json: { message: 'Privilege added successfully' }, status: :ok
      end

      def remove_privilege
        role_name = params[:id]
        privilege_name = params[:privilege]

        role_privilege = RolePrivilege.find_by(role: role_name, privilege: privilege_name)
        role_privilege&.destroy!

        render json: { message: 'Privilege removed successfully' }, status: :ok
      end

      private

      # Roles used to inline their whole user_roles/role_privileges rows — one entry per user
      # per role, each carrying a duplicate copy of the role itself (~540KB of the 634KB
      # payload). Clients only ever read the user tally, so send that instead. role_privileges
      # is dropped outright: `privileges` already carries the same set.
      def serialize_roles(roles)
        roles = roles.to_a
        # Arel.sql on the grouping column: UserRole's `role` column is shadowed by
        # `belongs_to :role`, so a plain group(:role).count hands back Role objects as keys
        # (one lookup each) instead of the role names we need to index by.
        user_counts = UserRole.where(role: roles.map(&:role))
                              .group(:role)
                              .pluck(Arel.sql('user_role.role'), Arel.sql('COUNT(*)'))
                              .to_h

        roles.map do |role|
          role.as_json(include: { privileges: {} })
              .merge('users_count' => user_counts[role.role] || 0)
        end
      end

      def role_params
        permitted_params = %i[role description uuid]
        permitted_params << :location_id if Role.location_scoped?

        params.permit(permitted_params)
      end

      def authorize_role_management
        return true if User.current&.is_superuser?

        render json: { errors: ['Only a Superuser can manage roles'] }, status: :forbidden
        false
      end

      def authorize_superuser_sync
        user_roles = User.current.roles.pluck(:role).map(&:to_s)
        return true if user_roles.any? { |role_name| role_name.downcase.include?('superuser') }

        render json: { errors: ['Only a Superuser can sync superuser privileges'] }, status: :forbidden
        false
      end

      def sync_location_id
        return nil unless Role.location_scoped?

        params[:location_id].presence || User.current.location_id
      end
    end
  end
end
