# frozen_string_literal: true

module Api
  module V1
    class PrivilegesController < ApplicationController
      def index
        privileges = paginate(Privilege.includes(:role_privileges, :roles))
        render json: privileges.as_json(include: { role_privileges: {}, roles: {} })
      end

      def show
        privilege = Privilege.includes(:role_privileges, :roles).find(params[:id])
        render json: privilege.as_json(include: { role_privileges: {}, roles: {} })
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

      def privilege_params
        params.require(:privilege).permit(:privilege, :description, :uuid)
      end
    end
  end
end
