# frozen_string_literal: true

module Api
  module V1
    class LabTestOrdersController < ApplicationController
      include LabTestsEngineLoader

      def index
        if params[:accession_number]
          orders = engine.find_orders_by_accession_number params[:accession_number]
          render json: orders
        elsif params[:patient_id]
          patient = Patient.find params[:patient_id]
          orders = engine.find_orders_by_patient patient
          # NOTE: orders can't be paginated here as it is just an ordinary array
          # not a queryset
          render json: orders
        else
          render json: { errors: ['accession_number or patient_id required'] },
                 status: :bad_request
        end
      end

      def create
        tests, encounter_id, requesting_clinician = params.require %i[
          tests encounter_id requesting_clinician
        ]

        begin
          date = TimeUtils.retro_timestamp(params[:date]&.to_time || Time.now)
        rescue ArgumentError => e
          error = "Failed to parse date(#{params[:date]}): #{e}"
          return render json: { errors: [error] }, status: :bad_request
        end

        encounter = Encounter.find encounter_id

        order = engine.create_order(tests:,
                                    encounter:,
                                    date:,
                                    requesting_clinician:)

        render json: order, status: :created
      end

      def create_external_order
        patient_id, accession_number = params.require(%i[patient_id accession_number])
        date = params[:date]&.to_date || Date.today
        patient = Patient.find(patient_id)

        render json: engine.create_external_order(patient, accession_number, date)
      end

      def create_legacy_order
        specimen_type, test_type, reason = params.require(%i[specimen_type test_type reason])
        date = params[:date]&.to_date || Date.today

        order = engine.create_legacy_order(patient, 'test_name' => test_type,
                                                    'sample_type' => specimen_type,
                                                    'reason_for_test' => reason,
                                                    'sample_status' => 'specimen_collected',
                                                    'date_sample_drawn' => date)

        render json: order, status: :created
      end

      def locations
        search_name = params[:search_name]

        locations_list = engine.lab_locations
        locations_list = locations_list.select { |location| location.include?(search_name) } if search_name

        render json: locations_list
      end

      def labs
        search_name = params[:search_name]

        labs_list = engine.labs
        labs_list = labs_list.select { |labs| labs.include?(search_name) } if search_name

        render json: labs_list
      end

      def orders_without_results
        render json: engine.orders_without_results(patient)
      end

      def hts_referral_orders
        sql = <<-SQL
          SELECT orders.order_id,
                encounter.program_id,
                encounter.location_id,
                encounter.provider_id,
                orders.patient_id,
                obs.value_text,
                (SELECT name FROM program WHERE program_id = encounter.program_id) AS program_name,
                (SELECT concept_id FROM concept_name WHERE name = obs.value_text) AS order_concept_id,
                (SELECT CONCAT(given_name,' ', family_name) FROM person_name WHERE person_id = encounter.provider_id) AS provider_name,
                (SELECT obs_id FROM obs where person_id = orders.patient_id AND order_id = orders.order_id  AND value_coded = order_concept_id) AS order_obs_id,
                (SELECT obs_id FROM obs where person_id = orders.patient_id AND concept_id = 7363 AND order_id = orders.order_id order by date_created desc limit 1 ) AS lab_result_obs_id,
                (SELECT value_text FROM obs where  order_id = orders.order_id AND obs_group_id = lab_result_obs_id AND concept_id = order_concept_id) AS lab_result_value
          FROM encounter
          INNER JOIN obs ON obs.encounter_id = encounter.encounter_id
          INNER JOIN orders ON orders.encounter_id = obs.encounter_id
                          AND orders.order_id = obs.order_id
          WHERE obs.concept_id = ?
        SQL

        sql_params = [7856]

        if params[:patient_id].present?
          sql += " AND encounter.patient_id = ?"
          sql_params << params[:patient_id]
        end

        # Filter by lab_result_value if the param is present
        if params[:filter_by_lab_result].present?
          sql = "SELECT * FROM (#{sql}) AS results WHERE lab_result_value IS NULL"
        end

        data = ActiveRecord::Base.connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([sql] + sql_params)
        )

        # exec_query returns an ActiveRecord::Result object that can be converted to hash
        render json: data.to_a
      end

      private

      def patient
        Patient.find(params[:patient_id])
      end
    end
  end
end
