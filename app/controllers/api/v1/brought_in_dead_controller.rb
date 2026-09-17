# frozen_string_literal: true

module Api
  module V1
    class BroughtInDeadController < ApplicationController
      # Number of brought-in-dead records, for the program dashboard card.
      #
      # GET /api/v1/brought_in_dead/count
      #
      # Optional parameters:
      #   program_id: Count this program's records only. Records saved without
      #               a program are always included.
      #   location_id: Defaults to the current user's location.
      def count
        filters = params.permit(:program_id, :location_id)

        render json: {
          count: BroughtInDeadService.count(
            program_id: filters[:program_id],
            location_id: filters[:location_id]
          )
        }
      end
    end
  end
end
