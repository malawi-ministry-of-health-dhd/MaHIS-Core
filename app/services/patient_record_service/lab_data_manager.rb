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
      lab_orders = operation_value_for(record, :labOrders) || {}
      unsaved_data = operation_value_for(lab_orders, :unsaved)
      return ok unless unsaved_data&.any?

      data_key         = data_type.to_s.underscore.to_sym
      collected_errors = []

      begin
        encounter_type = encounter_type_for!(data_key)
        encounter_id   = nil

        unsaved_data.each do |order_params|
          begin
            result = with_operation_guard(
              patient_id: patient_id,
              operation_type: 'lab_order.create',
              payload: order_params,
              target_type: 'LabOrder'
            ) do
              encounter_id ||= create_encounter(patient_id, encounter_type.id, record)
              order_params  = order_params.merge(encounter_id: encounter_id)
              order         = without_lab_patient_record_rebuild { Lab::OrdersService.order_test(order_params) }
              tests         = order.fetch(:tests)
              first_test    = tests.first
              raise "Lab order returned no tests for offline_id=#{operation_value_for(order_params, :offline_id)}" if first_test.blank?

              offline_id = operation_value_for(order_params, :offline_id)
              if offline_id.present?
                result = save_lab_results(:labResults, patient_id, record, offline_id, first_test[:id], tests)
                collected_errors.concat(result.errors) if result.errors.any?
                operation_value_for(lab_orders, :results)&.reject! { |entry| operation_value_for(entry, :offline_id) == offline_id } if result.success?
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
                value_coded:  first_test[:concept_id],
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
                  value_text:   first_test[:name],
                  order_id:     order.fetch(:order_id),
                  obs_datetime: record[:encounter_datetime],
                  location_id:  record[:location_id]
                })
              end

              order
            end

            next if result.skipped?
          rescue StandardError => e
            log_error("Failed to save lab order for order_params=#{operation_value_for(order_params, :offline_id)}", e)
            collected_errors << "Lab order #{operation_value_for(order_params, :offline_id)}: #{e.message}"
            # continues to next order
          end
        end

        assign_nested_operation_value(record, data_type, :unsaved, [])
        OperationResult.new(success: true, errors: collected_errors)
      rescue StandardError => e
        log_and_fail("Failed to save #{data_type} information", e)
      end
    end

    def create_observation(encounter_id, params)
      encounter = Encounter.unscoped.find(encounter_id)
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

    def save_lab_results(data_type, patient_id, record, offline_id = nil, test_obs_id = nil, order_tests = nil)
      lab_orders = operation_value_for(record, :labOrders) || {}
      hydrate_lab_result_measures!(lab_orders)

      # Prune result entries that carry no measures. They represent nothing to
      # save (typically stale entries left in the record from an aborted/empty
      # submission). Removing them from the record stops them being re-submitted
      # and re-reported on every sync, and keeps a single empty entry from
      # flipping the whole operation to "failed" (which would block the
      # labOrders rebuild that clears processed results).
      results_ref = operation_value_for(lab_orders, :results)
      results_ref.reject! { |result| result.respond_to?(:key?) && lab_result_measures_blank?(result) } if results_ref.is_a?(Array)

      unsaved_data = Array.wrap(operation_value_for(lab_orders, :results)).flatten(1).compact

      if offline_id.present? && unsaved_data.any?
        unsaved_data = unsaved_data.select { |result| operation_value_for(result, :offline_id) == offline_id }
      end

      return ok unless unsaved_data.any?

      data_key         = data_type.to_s.underscore.to_sym
      collected_errors = []

      unsaved_data.each do |order_params|
        begin
          result = with_operation_guard(
            patient_id: patient_id,
            operation_type: 'lab_result.create',
            payload: order_params,
            target_type: 'LabResult'
          ) do
            effective_test_id = resolve_result_test_id(order_params, order_tests, test_obs_id)

            if effective_test_id.blank?
              collected_errors << "Skipped result offline_id=#{operation_value_for(order_params, :offline_id)}: test_id missing"
              next
            end

            encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[data_key])
            encounter_id   = create_encounter(patient_id, encounter_type.id, record)
            lab_results    = lab_result_payload(order_params, encounter_id)

            without_lab_patient_record_rebuild do
              Lab::ResultsService.create_results(effective_test_id, lab_results, 'user entered')
            end
          end

          next if result.skipped?
        rescue StandardError => e
          result_identifier = operation_value_for(order_params, :offline_id)
          log_error("Failed to save lab result offline_id=#{result_identifier}", e)
          collected_errors << "Lab result #{result_identifier}: #{e.message}"
          # continues to next result
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("Failed to save #{data_type} information", e)
    end

    # Offline results carry no per-test obs id. For a multi-test order every
    # result would otherwise collapse onto the first test (test_obs_id). Match
    # each result back to its test by concept when the client provided one,
    # falling back to the first test (legacy behaviour) for single-test orders
    # or older records that predate test_concept_id.
    def resolve_result_test_id(order_params, order_tests, fallback_test_id)
      concept_id = operation_value_for(order_params, :test_concept_id)
      if concept_id.present? && order_tests.present?
        match = Array.wrap(order_tests).find do |test|
          operation_value_for(test, :concept_id).to_s == concept_id.to_s
        end
        matched_id = match && operation_value_for(match, :id)
        return matched_id if matched_id.present?
      end

      fallback_test_id.presence || operation_value_for(order_params, :test_id)
    end

    def void_lab_order(_patient_id, record)
      data = record.dig(:labOrders, :voided)
      return ok unless data&.any?

      collected_errors = []

      data.each do |item|
        begin
          result = with_operation_guard(
            patient_id: _patient_id,
            operation_type: 'lab_order.void',
            payload: item,
            target_type: 'LabOrder'
          ) do
            without_lab_patient_record_rebuild do
              Lab::OrdersService.void_order(item[:orderId], item[:reason])
            end
            Lab::VoidOrderJob.perform_later(item[:orderId])
            { target_type: 'LabOrder', target_id: item[:orderId] }
          end

          next if result.skipped?
        rescue StandardError => e
          log_error("Failed to void lab order #{item[:orderId]}", e)
          collected_errors << "Order #{item[:orderId]}: #{e.message}"
        end
      end

      record[:labOrders][:voided] = []
      OperationResult.new(success: true, errors: collected_errors)
    end

    def encounter_type_for!(data_key)
      encounter_type_name = ENCOUNTER_TYPE_MAPPING[data_key]
      raise "Encounter type mapping missing for #{data_key}" if encounter_type_name.blank?

      encounter_type = EncounterType.find_by_name(encounter_type_name) ||
                       EncounterType.unscoped.where('LOWER(name) = ?', encounter_type_name.downcase).first
      raise "Encounter type #{encounter_type_name} not found" if encounter_type.blank?

      encounter_type
    end

    def without_lab_patient_record_rebuild
      previous = Thread.current[:skip_lab_patient_record_rebuild]
      Thread.current[:skip_lab_patient_record_rebuild] = true
      yield
    ensure
      Thread.current[:skip_lab_patient_record_rebuild] = previous
    end

    def lab_result_measures_blank?(result)
      Array.wrap(operation_value_for(result, :measures)).flatten(1).compact.empty?
    end

    def hydrate_lab_result_measures!(lab_orders)
      results_ref = operation_value_for(lab_orders, :results)
      return unless results_ref.is_a?(Array)

      results_ref.each do |result|
        next unless result.respond_to?(:[]=)
        next unless lab_result_measures_blank?(result)

        measures = lab_result_measures_from_matching_test(lab_orders, result)
        assign_operation_value(result, :measures, measures) if measures.present?
      end
    end

    def lab_result_measures_from_matching_test(lab_orders, result)
      test = find_lab_result_test(lab_orders, result)
      Array.wrap(operation_value_for(test, :result)).flatten(1).compact
    end

    def find_lab_result_test(lab_orders, result)
      result_test_id = operation_value_for(result, :test_id).presence
      return find_lab_test_by_id(lab_orders, result_test_id) if result_test_id.present?

      offline_id = operation_value_for(result, :offline_id).presence
      return nil if offline_id.blank?

      order = lab_orders_for_result(lab_orders).find { |candidate| operation_value_for(candidate, :offline_id).to_s == offline_id.to_s }
      return nil unless order

      tests = Array.wrap(operation_value_for(order, :tests)).compact
      concept_id = operation_value_for(result, :test_concept_id).presence
      if concept_id.present?
        concept_match = tests.find { |test| operation_value_for(test, :concept_id).to_s == concept_id.to_s }
        return concept_match if concept_match
      end

      tests_with_results = tests.select { |test| Array.wrap(operation_value_for(test, :result)).flatten(1).compact.any? }
      tests_with_results.one? ? tests_with_results.first : nil
    end

    def find_lab_test_by_id(lab_orders, test_id)
      lab_orders_for_result(lab_orders).each do |order|
        Array.wrap(operation_value_for(order, :tests)).each do |test|
          return test if operation_value_for(test, :id).to_s == test_id.to_s
        end
      end

      nil
    end

    def lab_orders_for_result(lab_orders)
      Array.wrap(operation_value_for(lab_orders, :saved)) + Array.wrap(operation_value_for(lab_orders, :unsaved))
    end

    def assign_operation_value(container, key, value)
      return unless container.respond_to?(:[]=)

      target_key = if container.respond_to?(:key?) && container.key?(key.to_s)
                     key.to_s
                   else
                     key
                   end
      container[target_key] = value
    end

    def assign_nested_operation_value(container, parent_key, child_key, value)
      parent = operation_value_for(container, parent_key)
      return unless parent.respond_to?(:[]=)

      assign_operation_value(parent, child_key, value)
    end

    def lab_result_payload(order_params, encounter_id)
      params = normalize_lab_result_value(order_params)
      measures = Array.wrap(operation_value_for(params, :measures)).flatten(1).compact
      raise "Lab result measures missing for offline_id=#{operation_value_for(params, :offline_id)}" if measures.empty?

      {
        encounter_id: encounter_id,
        date: operation_value_for(params, :date),
        comments: operation_value_for(params, :comments),
        provider_id: operation_value_for(params, :provider_id),
        measures: measures.map { |measure| normalize_lab_result_value(measure) }
      }.compact.with_indifferent_access
    end

    def normalize_lab_result_value(value)
      case value
      when ActionController::Parameters
        normalize_lab_result_value(value.to_unsafe_h)
      when Hash
        value.each_with_object({}.with_indifferent_access) do |(key, nested_value), hash|
          hash[key] = normalize_lab_result_value(nested_value)
        end
      when Array
        value.map { |nested_value| normalize_lab_result_value(nested_value) }
      else
        value
      end
    end

    def operation_value_for(container, key)
      return nil if container.nil? || !container.respond_to?(:[])

      if container.respond_to?(:key?)
        return container[key] if container.key?(key)
        return container[key.to_s] if container.key?(key.to_s)
      end

      container[key] || container[key.to_s]
    rescue TypeError
      nil
    end
  end
end
