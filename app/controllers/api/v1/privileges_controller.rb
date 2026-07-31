# frozen_string_literal: true

module Api
  module V1
    class PrivilegesController < ApplicationController
      def index
        render json: serialize_privileges(paginate(Privilege.all))
      end

      def show
        render json: serialize_privileges([Privilege.find(params[:id])]).first
      end

      def create
        privilege = Privilege.create!(privilege_params)
        render json: privilege, status: :created
      end

      def update
        privilege = Privilege.find(params[:id])
        privilege.update!(privilege_params)
        render json: privilege
      end

      def destroy
        privilege = Privilege.find(params[:id])
        privilege.destroy!
        head :no_content
      end

      private

      # Same story as roles: the inlined role_privileges/roles rows were only ever read for
      # their size (~260KB of payload), so send the role tally instead.
      def serialize_privileges(privileges)
        privileges = privileges.to_a
        # Arel.sql on the grouping column — see the note in RolesController#serialize_roles;
        # RolePrivilege's `privilege` column is likewise shadowed by `belongs_to :privilege`.
        role_counts = RolePrivilege.where(privilege: privileges.map(&:privilege))
                                   .group(:privilege)
                                   .pluck(Arel.sql('role_privilege.privilege'), Arel.sql('COUNT(*)'))
                                   .to_h

        privileges.map do |privilege|
          privilege.as_json.merge('roles_count' => role_counts[privilege.privilege] || 0)
        end
      end

      def privilege_params
        params.require(:privilege).permit(:privilege, :description, :uuid)
      end
    end
  end
end
