# frozen_string_literal: true

module Api
  module V1
    class StagesController < ApplicationController
      include CouchdbSync

      def index
        stages = stages_service.find_stages(index_filters)
        render json: paginate(stages).map { |stage| stages_service.serialize(stage) }, status: :ok
      end

      def show
        render json: stages_service.serialize(stages_service.find_stage(params[:id])), status: :ok
      end

      def active_stages
        current_location_id = User.current.location_id
        if current_location_id.nil?
          render json: { errors: 'Current user does not have a location assigned' }, status: :unprocessable_entity
          return
        end

        stages = stages_service.active_stages(current_location_id)
        render json: paginate(stages).map { |stage| stages_service.serialize(stage) }, status: :ok
      end

      def create
        data = stages_service.create_stage(stage_params)
        sync_to_couchdb(data, 'stages', data[:identifier] || data[:patient_id].to_s)
        render json: data, status: :created
      end

      def update
        data = stages_service.update_stage(params[:id], stage_params)
        sync_to_couchdb(data, 'stages', data[:identifier] || data[:patient_id].to_s)
        render json: data, status: :ok
      end

      private

      def stages_service
        @stages_service ||= StagesService.new
      end

      def stage_params
        # Keep arrivalTime permitted for backward compatibility; service controls when it is applied.
        params.permit(:patient_id, :identifier, :stage, :arrivalTime, :arrival_time, :location_id)
      end

      def index_filters
        params.permit(:stage, :location_id, :patient_id, :identifier)
      end
    end
  end
end
