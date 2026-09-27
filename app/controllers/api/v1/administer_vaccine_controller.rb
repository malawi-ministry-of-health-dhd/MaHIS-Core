module Api
  module V1
    class AdministerVaccineController < ApplicationController
      def administer_vaccine
        params.permit!
        encounter_id, drug_orders, program_id, obs_archetypes = params.require(%i[encounter_id drug_orders program_id observations])
        observations = AdministerVaccineService.administer_vaccine(encounter_id, drug_orders, program_id, obs_archetypes, params[:provider_id])
        render json: observations, status: :ok
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end