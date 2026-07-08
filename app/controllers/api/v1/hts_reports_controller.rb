# frozen_string_literal: true

module Api
  module V1
    class HtsReportsController < ApplicationController
      #before_action :validate_params
      def index
        report = service.generate_report(name: @name,
                                         type: @name,
                                         start_date: @start_date,
                                         end_date: @end_date,
                                         quarter: @quarter,
                                         year: @year)

        if report
          render json: report
        else
          render status: :no_content
        end
      end

      def daily_stats
        filters = params.permit(%i[order_type_id patient_id accession_number date status location_id])
        filters[:location_id] ||= dashboard_location_id
        render json: HtsService::Dashboard.dashboard_stats(filters)
      end

      def daily_stats_patients
        filters = params.permit(%i[category order_type_id date search page per_page location_id])
        filters[:location_id] ||= dashboard_location_id
        render json: HtsService::Dashboard.dashboard_patients(filters)
      end

      private

      # Facility scope for the HTS dashboard: the caller's current location, so
      # the online dashboard counts the same per-facility population the offline
      # dashboard does. Falls back to the authenticated user's location.
      def dashboard_location_id
        Location.current&.id || User.current&.location_id
      end

      def validate_params
        permitted = params.permit(%i[start_date end_date name quarter year]).to_h
        @start_date, @end_date, @name, @quarter, @year = permitted.values_at(:start_date, :end_date, :name, :quarter,
                                                                             :year)
        if !@start_date.blank? && !@end_date.blank?
          handle_errors 'start date cannot be greater than end date', 'start_date' if @start_date > @end_date
          handle_errors 'end date cannot be greater than today', 'end_date' if @end_date.to_date > Date.today
        end
        handle_errors 'name cannot be blank', 'name' if @name.blank?
      end

      def handle_errors(message, entity)
        error = UnprocessableEntityError.new(message)
        error.add_entity(entity)
        raise error
      end

      def service
        ReportService.new(program_id: 18, overwrite_mode: false)
      end
    end
  end
end
