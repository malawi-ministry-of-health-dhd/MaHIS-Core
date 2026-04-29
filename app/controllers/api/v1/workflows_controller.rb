# frozen_string_literal: true

module Api
  module V1
    class WorkflowsController < ApplicationController
      # Retrieves patient's next encounter given previous encounters
      # and enrolled program
      def next_encounter
        encounter = service.next_encounter

        if encounter
          render json: encounter
        else
          render status: :no_content
        end
      end

      # Returns a flat visit context object for offline workflow decisions
      def visit_context
        context = service.visit_context

        if context
          render json: context
        else
          render json: { error: 'Visit context not available for this program' }, status: :not_implemented
        end
      end

      private

      def service
        return @service if @service

        program_id, patient_id = params.require %i[program_id patient_id]
        date = params[:date]

        @service = WorkflowService.new(program_id:,
                                       patient_id:,
                                       date:)
        @service
      end
    end
  end
end
