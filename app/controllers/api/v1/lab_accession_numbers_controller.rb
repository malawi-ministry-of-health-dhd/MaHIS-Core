# frozen_string_literal: true

module Api
  module V1
    class LabAccessionNumbersController < ApplicationController
      def top_up
        result = service.ensure_pool_for_location(
          location_id: params[:location_id].presence || User.current&.location_id,
          target_count: params[:target_count],
          count: params[:count]
        )

        render json: result, status: :ok
      rescue LabAccessionNumberPoolService::AccessionPoolError => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      end

      def top_up_all
        render json: service.ensure_pool_for_all_facilities(target_count: params[:target_count]), status: :ok
      end

      def reserve
        documents = service.reserve_for_device(
          location_id: params[:location_id].presence || User.current&.location_id,
          device_id: params[:device_id],
          count: params[:count]
        )

        render json: {
          count: documents.length,
          accession_numbers: documents
        }, status: :ok
      rescue LabAccessionNumberPoolService::AccessionPoolError => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      end

      private

      def service
        @service ||= LabAccessionNumberPoolService.new
      end
    end
  end
end
