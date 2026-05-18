# frozen_string_literal: true

module Api
  module V1
    class MnhController < ApplicationController
      def stats
        program_id = params.require(:program_id)
        date = params[:date]
        stats = mnh_engine.stats(program_id, date, location_id: params[:location_id])
        render json: stats
      rescue ActiveRecord::RecordNotFound => e
        render json: { errors: [e.message] }, status: :not_found
      rescue ArgumentError => e
        render json: { errors: [e.message] }, status: :not_found
      rescue StandardError => e
        log_and_render_error(e, 'stats')
      end

      def anc_stats
        program_id = params[:program_id]
        date = params[:date]
        stats = mnh_engine.anc_stats(program_id, date, location_id: params[:location_id])
        render json: stats
      rescue ActiveRecord::RecordNotFound => e
        render json: { errors: [e.message] }, status: :not_found
      rescue ArgumentError => e
        render json: { errors: [e.message] }, status: :not_found
      rescue StandardError => e
        log_and_render_error(e, 'anc_stats')
      end

      private

      def mnh_engine
        @mnh_engine ||= MnhService::Engine.new
      end

      def log_and_render_error(error, action)
        Rails.logger.error("[MnhController##{action}] #{error.class}: #{error.message}\n#{error.backtrace.first(8).join("\n")}")
        render json: { errors: [error.message], error_class: error.class.name }, status: :internal_server_error
      end
    end
  end
end
