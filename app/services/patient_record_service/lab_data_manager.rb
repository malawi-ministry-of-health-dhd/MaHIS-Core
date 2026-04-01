# app/services/patient_record_service/lab_data_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class LabDataManager < BaseSaver
    ENCOUNTER_TYPE_MAPPING = SavePatientRecordService::ENCOUNTER_TYPE_MAPPING

    def save_lab_orders_data(patient_id, record)
      save_lab_order(:labOrders, patient_id, record)
    end

    def save_lab_results_data(patient_id, record)
      save_lab_results(:labResults, patient_id, record)
    end

    def save_lab_order(data_type, patient_id, record)
      unsaved_data = record.dig(:labOrders, :unsaved)
      return ok unless unsaved_data&.any?

      data_key         = data_type.to_s.underscore.to_sym
      collected_errors = []

      begin
        encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
        encounter_id   = create_encounter(patient_id, encounter_type.id, record)

        unsaved_data.each do |order_params|
          begin
            order_params  = order_params.merge(encounter_id: encounter_id)
            order         = Lab::OrdersService.order_test(order_params)
            tests         = order.fetch(:tests)

            if order_params[:offline_id].present?
              result = save_lab_results(:labResults, patient_id, record, order_params[:offline_id], tests[0][:id])
              collected_errors.concat(result.errors) if result.errors.any?
            end

            person_making_request = ConceptName.find_by(name: "Person making request")&.concept_id
            test_type             = ConceptName.find_by(name: "Test type")&.concept_id
            reason_for_test       = ConceptName.find_by(name: "Reason for test")&.concept_id
            refer_to_htc          = ConceptName.find_by(name: "Refer to HTC")&.concept_id

            create_observation(encounter_id, {
              concept_id:     person_making_request,
              value_text:     order_params[:requesting_clinician],
              obs_datetime:   record[:encounter_datetime],
              location_id:    record[:location_id]
            })
            create_observation(encounter_id, {
              concept_id:   test_type,
              value_coded:  tests[0][:concept_id],
              obs_datetime: record[:encounter_datetime],
              location_id:  record[:location_id]
            })
            create_observation(encounter_id, {
              concept_id:   reason_for_test,
              value_coded:  order_params[:reason_for_test_id],
              obs_datetime: record[:encounter_datetime],
              location_id:  record[:location_id]
            })

            if order_params[:referral] == "referral"
              create_observation(encounter_id, {
                concept_id:   refer_to_htc,
                value_text:   tests[0][:name],
                order_id:     order.fetch(:order_id),
                obs_datetime: record[:encounter_datetime],
                location_id:  record[:location_id]
              })
            end

            enqueue_lab_push_order(order.fetch(:order_id), order_params[:offline_id])
          rescue StandardError => e
            log_error("Failed to save lab order for order_params=#{order_params[:offline_id]}", e)
            collected_errors << "Lab order #{order_params[:offline_id]}: #{e.message}"
            # continues to next order
          end
        end

        record[data_type][:unsaved] = []
        OperationResult.new(success: true, errors: collected_errors)
      rescue StandardError => e
        log_and_fail("Failed to save #{data_type} information", e)
      end
    end

    def create_observation(encounter_id, params)
      encounter = Encounter.find(encounter_id)
      observation_service.create_observation(encounter, params)
    end

    def enqueue_lab_push_order(order_id, offline_id = nil)
      specimen_name = specimen_catalogue_name(order_id)
      if specimen_name.blank?
        Rails.logger.warn("Skipping Lab::PushOrderJob for order_id=#{order_id} offline_id=#{offline_id}: specimen catalogue name is missing")
        return
      end

      Lab::PushOrderJob.perform_later(order_id)
    end

    def specimen_catalogue_name(order_id)
      order = Lab::LabOrder.unscoped.find_by(order_id: order_id)
      return nil unless order&.concept_id

      ConceptAttribute
        .find_by(concept_id: order.concept_id, attribute_type: ConceptAttributeType.test_catalogue_name)
        &.value_reference
    rescue StandardError => e
      Rails.logger.warn("Failed to resolve specimen catalogue name for order_id=#{order_id}: #{e.message}")
      nil
    end

    def save_lab_results(data_type, patient_id, record, offline_id = nil, test_obs_id = nil)
      unsaved_data = record.dig(:labOrders, :results)

      if offline_id.present? && unsaved_data&.any?
        unsaved_data = unsaved_data.select { |result| result[:offline_id] == offline_id }
      end

      return ok unless unsaved_data&.any?

      data_key         = data_type.to_s.underscore.to_sym
      collected_errors = []

      unsaved_data.each do |order_params|
        begin
          if test_obs_id.blank? && order_params[:offline_id].present?
            collected_errors << "Skipped result offline_id=#{order_params[:offline_id]}: test_obs_id missing"
            next
          end

          encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
          encounter_id   = create_encounter(patient_id, encounter_type.id, record)
          order_params   = order_params.merge(test_id: test_obs_id) if test_obs_id
          lab_results    = order_params.merge(encounter_id: encounter_id)

          Lab::ResultsService.create_results(lab_results[:test_id], lab_results)
        rescue StandardError => e
          log_error("Failed to save lab result offline_id=#{order_params[:offline_id]}", e)
          collected_errors << "Lab result #{order_params[:offline_id]}: #{e.message}"
          # continues to next result
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("Failed to save #{data_type} information", e)
    end

    def void_lab_order(_patient_id, record)
      data = record.dig(:labOrders, :voided)
      return ok unless data&.any?

      collected_errors = []

      data.each do |item|
        begin
          Lab::OrdersService.void_order(item[:orderId], item[:reason])
          Lab::VoidOrderJob.perform_later(item[:orderId])
        rescue StandardError => e
          log_error("Failed to void lab order #{item[:orderId]}", e)
          collected_errors << "Order #{item[:orderId]}: #{e.message}"
        end
      end

      record[:labOrders][:voided] = []
      OperationResult.new(success: true, errors: collected_errors)
    end
  end
end
