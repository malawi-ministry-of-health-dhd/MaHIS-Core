# frozen_string_literal: true

module Api
  module V1
    # The IPD dashboard's ward roster. #index serves one page of the list and
    # #summary the ward-wide counts and side panels, so the dashboard never has
    # to hold every admitted patient to render a card that shows eight.
    class WardPatientsController < ApplicationController
      def index
        render json: WardPatientsService.patients(roster_filters), status: :ok
      end

      def summary
        render json: WardPatientsService.summary(roster_filters), status: :ok
      end

      private

      def roster_filters
        params.permit(:ward_id, :program_id, :page, :page_size, :per_page, :search, :status, :has_specialty_request)
              .to_h.symbolize_keys
      end
    end
  end
end
