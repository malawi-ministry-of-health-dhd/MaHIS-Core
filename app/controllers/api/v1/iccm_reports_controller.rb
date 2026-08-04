# frozen_string_literal: true

module Api
  module V1
    class IccmReportsController < ApplicationController
      def daily_stats
        location_id = params[:location_id].presence || dashboard_location_id
        render json: IccmService::Dashboard.dashboard_stats(location_id: location_id)
      end

      private
      
      def dashboard_location_id
        Location.current&.id || User.current&.location_id
      end
    end
  end
end
