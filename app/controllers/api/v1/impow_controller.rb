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
      rescue StandardError => e
        Rails.logger.error("Error fetching batch anthropometry patients: #{e.message}")
        render json: { error: e.message }, status: :internal_server_error
      end

      # GET /api/v1/impow/metrics
      # Get active caseload metrics for the current month
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      def metrics
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today
        location_id = Location.current.location_id

        cache_key = "impow_metrics_#{program_id}_#{date}_#{location_id}"

        # Try to get from cache first
        cached_result = Rails.cache.read(cache_key)
        
        if cached_result
          render json: cached_result
        else
          # Metrics are being calculated in background, trigger job and return calculating status
          ImpowMetricsJob.perform_async(program_id, date.to_s, location_id)
          render json: { calculating: true, ots: 0, sfs: 0, defaulters: 0 }
        end
      rescue StandardError => e
        Rails.logger.error("Error fetching metrics: #{e.message}")
        render json: { error: e.message }, status: :internal_server_error
      end
    end
  end
end
