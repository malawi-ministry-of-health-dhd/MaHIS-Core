# frozen_string_literal: true

module Api
  module V1
    class FacilityReferralsController < ApplicationController
      # GET /api/v1/faciliy_referrals
      def index
        render json: FacilityReferralService.new.index(referral_filters), status: :ok
      end

      private

      def referral_filters
        params.permit(
          :patient_id,
          :program_id,
          :location_id,
          :date_from,
          :date_to
        )
      end
    end
  end
end
