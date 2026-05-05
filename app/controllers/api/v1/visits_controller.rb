module Api
  module V1
    class Api::V1::VisitsController < ApplicationController
      include CouchdbSync

      def check_patient_status
        patient_id = params[:patient_id]
        visit = Visit.where(patient_id: patient_id, date_stopped: nil)
        render json: visit, status: :ok
      end

      def create
        data = VisitService.new.create_visit(visit_params)
        create_couchdb_visit(data)
        render json: data
      end

      def create_couchdb_visit(doc_data)
        doc_id = generate_document_id(doc_data)
        sync_to_couchdb(doc_data, 'visits', doc_id)
      end

      def generate_document_id(visit)
        # Create composite _id from identifier and start_date
        identifier = visit[:identifier] || 'unknown'
        start_date = visit['date_started'] ? visit['date_started'].to_time.strftime('%Y-%m-%dT%H:%M:%S') : 'no-date'
        "#{identifier}_#{start_date}"
      end

      def index
        patient_id = params[:patient_id]
        patient_id = find_patient_id_by_identifier(params[:identifier]) if params[:identifier].present?

        visits = base_visits_scope
        visits = visits.where(patient_id: patient_id) if patient_id.present?
        visits = filter_by_program(visits, params[:program_id])
        visits = filter_by_date_started(visits, params[:date])
        visits = filter_by_date_stopped(visits, params[:date_stopped])

        render json: visits.map { |visit| visit_response(visit) }, status: :ok
      end

      def close
        render json: VisitService.new.close_visit(visit_params)
      end

      def generate_visit_number
        visit_number = VisitService.next_daily_visit_number!

        render json: { next_visit_number: visit_number }, status: :ok
      end

      private

      def visit_params
        params.permit(
          :patient_id, :identifier, :date_started, :full_name, :date_stopped,
          :program_id, :location_id, :stage, :visit_type_id
        )
      end

      def base_visits_scope
        Visit
          .select(
            'visit.*',
            'patient_identifier.identifier AS identifier',
            "#{full_name_sql} AS full_name"
          )
          .where(location_id: User.current.location_id)
          .joins(
            'INNER JOIN patient_identifier '\
            'ON patient_identifier.patient_identifier_id = ('\
            'SELECT latest_identifier.patient_identifier_id '\
            'FROM patient_identifier latest_identifier '\
            'WHERE latest_identifier.patient_id = visit.patient_id '\
            'AND latest_identifier.identifier_type = 3 '\
            'AND latest_identifier.voided = 0 '\
            'ORDER BY latest_identifier.preferred DESC, '\
            'latest_identifier.date_created DESC, '\
            'latest_identifier.patient_identifier_id DESC '\
            'LIMIT 1)'
          )
          .joins(
            'LEFT JOIN person_name '\
            'ON person_name.person_name_id = ('\
            'SELECT latest_name.person_name_id '\
            'FROM person_name latest_name '\
            'WHERE latest_name.person_id = visit.patient_id '\
            'AND latest_name.voided = 0 '\
            'ORDER BY latest_name.date_created DESC, latest_name.person_name_id DESC '\
            'LIMIT 1)'
          )
      end

      def filter_by_program(visits, program_id)
        return visits.where('EXISTS (SELECT 1 FROM encounter WHERE encounter.visit_id = visit.visit_id)') if program_id.blank?

        visits.where(
          'EXISTS ('\
          'SELECT 1 FROM encounter '\
          'WHERE encounter.visit_id = visit.visit_id '\
          'AND encounter.program_id = ?'\
          ')',
          program_id
        )
      end

      def filter_by_date_started(visits, date)
        return visits if date.blank?

        start_time, end_time = TimeUtils.day_bounds(date)
        visits.where(date_started: start_time..end_time)
      end

      def filter_by_date_stopped(visits, date_stopped)
        return visits.where(date_stopped: nil) if date_stopped == 'null'
        return visits if date_stopped.blank?

        start_time, end_time = TimeUtils.day_bounds(date_stopped)
        visits.where(date_stopped: start_time..end_time)
      end

      def find_patient_id_by_identifier(identifier)
        PatientIdentifier.find_by(identifier: identifier, identifier_type: 3)&.patient_id
      end

      def visit_response(visit)
        visit.attributes.except('identifier', 'full_name').merge(
          identifier: visit[:identifier],
          full_name: visit[:full_name]
        )
      end

      def full_name_sql
        <<~SQL.squish
          CASE
            WHEN person_name.person_name_id IS NULL THEN NULL
            WHEN person_name.middle_name IS NULL
              OR TRIM(person_name.middle_name) = ''
              OR UPPER(TRIM(person_name.middle_name)) IN ('N/A', 'N\\A', 'NA', 'UNKNOWN')
              THEN CONCAT_WS(' ', person_name.given_name, person_name.family_name)
            ELSE CONCAT_WS(' ', person_name.given_name, person_name.middle_name, person_name.family_name)
          END
        SQL
      end
    end
  end
end
