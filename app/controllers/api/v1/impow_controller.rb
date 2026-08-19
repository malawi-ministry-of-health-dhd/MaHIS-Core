# frozen_string_literal: true

module Api
  module V1
    class ImpowController < ApplicationController
      before_action :authenticate

      # GET /api/v1/impow/expected_patients
      # Get patients expected for clinic day based on appointment dates
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      #   - page: optional (defaults to 1)
      #   - per_page: optional (defaults to 10)
      def expected_patients
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today
        page = params[:page] || 1
        per_page = params[:per_page] || 10

        program = Program.find(program_id)
        
        service = ImpowService::ExpectedPatientsEngine.new(
          program: program,
          date: date,
          page: page,
          per_page: per_page
        )
        
        result = service.fetch_expected_patients

        render json: result
      rescue ActionController::ParameterMissing => e
        render json: { error: 'Missing required parameter' }, status: :bad_request
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Program not found' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error("Error fetching expected patients: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { error: 'Internal server error' }, status: :internal_server_error
      end

      # GET /api/v1/impow/pending_enrollments
      # Get patients referred to IMPOW (OS Program) but not yet enrolled
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      #   - page: optional (defaults to 1)
      #   - per_page: optional (defaults to 10)
      def pending_enrollments
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today
        page = params[:page] || 1
        per_page = params[:per_page] || 10

        program = Program.find(program_id)
        
        service = ImpowService::PendingEnrollmentsEngine.new(
          program: program,
          date: date,
          page: page,
          per_page: per_page
        )
        
        result = service.fetch_pending_enrollments

        render json: result
      rescue ActionController::ParameterMissing => e
        render json: { error: 'Missing required parameter' }, status: :bad_request
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Program not found' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error("Error fetching pending enrollments: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { error: 'Internal server error' }, status: :internal_server_error
      end

      # GET /api/v1/impow/batch_anthropometry/patients
      # Get patients who have completed triage but not anthropometry for today
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      #   - page: optional (defaults to 1)
      #   - per_page: optional (defaults to 20)
      def batch_anthropometry_patients
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today
        page = params[:page] || 1
        per_page = params[:per_page] || 20

        program = Program.find(program_id)
        
        service = ImpowService::BatchAnthropometryEngine.new(
          program: program,
          date: date,
          page: page,
          per_page: per_page
        )
        
        result = service.fetch_patients_awaiting_anthropometry

        render json: result
      rescue ActionController::ParameterMissing => e
        render json: { error: 'Missing required parameter' }, status: :bad_request
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Program not found' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error("Error fetching batch anthropometry patients: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { error: 'Internal server error' }, status: :internal_server_error
      end

      # GET /api/v1/impow/batch_medical_assessment/patients
      # Get patients who have done anthropometry but not medical assessment
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      #   - page: optional (defaults to 1)
      #   - per_page: optional (defaults to 20)
      def batch_medical_assessment_patients
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today
        page = params[:page] || 1
        per_page = params[:per_page] || 20

        program = Program.find(program_id)
        
        service = ImpowService::BatchMedicalAssessmentEngine.new(
          program: program,
          date: date,
          page: page,
          per_page: per_page
        )
        
        result = service.fetch_patients_awaiting_assessment

        render json: result
      rescue ActionController::ParameterMissing => e
        render json: { error: 'Missing required parameter' }, status: :bad_request
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Program not found' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error("Error fetching batch medical assessment patients: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { error: 'Internal server error' }, status: :internal_server_error
      end

      # GET /api/v1/impow/batch_dispensation/patients
      # Get patients who have done prescription/treatment but not dispensing
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      #   - page: optional (defaults to 1)
      #   - per_page: optional (defaults to 20)
      def batch_dispensation_patients
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today
        page = params[:page] || 1
        per_page = params[:per_page] || 20

        program = Program.find(program_id)
        
        service = ImpowService::BatchDispensationEngine.new(
          program: program,
          date: date,
          page: page,
          per_page: per_page
        )
        
        result = service.fetch_patients_awaiting_dispensation

        render json: result
      rescue ActionController::ParameterMissing => e
        render json: { error: 'Missing required parameter' }, status: :bad_request
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Program not found' }, status: :not_found
      rescue StandardError => e
        Rails.logger.error("Error fetching batch dispensation patients: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        render json: { error: 'Internal server error' }, status: :internal_server_error
      end
    end
  end
end
