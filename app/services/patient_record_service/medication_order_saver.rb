# app/services/patient_record_service/medication_order_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class MedicationOrderSaver < BaseSaver
    ENCOUNTER_TYPE_MAPPING = SavePatientRecordService::ENCOUNTER_TYPE_MAPPING
    NCD_PROGRAM_ID = 32

    def save_medication_order(patient_id, record)
      collected_errors = []
      treatment_plan_values = []

      # Standard path: MedicationOrder.unsaved
      orders_unsaved = record.dig(:MedicationOrder, :unsaved) || []
      orders_unsaved.each do |order|
        next unless order

        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[:treatment])
            encounter_id   = create_encounter(patient_id, encounter_type.id, record)
            encounter      = Encounter.find(encounter_id)

            unless encounter.type.name.casecmp?('TREATMENT')
              Rails.logger.warn("Unexpected encounter type: #{encounter.type.name} for encounter ##{encounter.encounter_id}")
              next
            end

            saved_drug_orders = DrugOrderService.create_drug_orders(encounter: encounter, drug_orders: [order])
            raise "Drug order creation returned empty result for order: #{order.inspect}" if saved_drug_orders.blank?
            treatment_plan_values.concat(saved_drug_orders.map(&:to_s))

            dispensation_result = save_dispensation_data(
              patient_id,
              record,
              saved_drug_orders[0].order_id,
              fetch_value(order, :dispensation)
            )
            collected_errors.concat(dispensation_result.errors) if dispensation_result.errors.any?
          end
        rescue StandardError => e
          log_error("Failed to create medication order", e)
          collected_errors << "Order #{order.inspect}: #{e.message}"
        end
      end

      # Offline path: art_orders_pending — drug orders captured while offline
      pending_orders = fetch_value(record, :art_orders_pending) || []
      Array.wrap(pending_orders).each do |entry|
        next unless entry
        next unless within_session_day?(entry)

        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            encounter_type = EncounterType.find_by_name(ENCOUNTER_TYPE_MAPPING[:treatment])
            encounter_datetime = parse_encounter_datetime(entry)
            entry_record = record.merge(encounter_datetime: encounter_datetime)

            encounter_id = create_encounter(patient_id, encounter_type.id, entry_record)
            encounter    = Encounter.find(encounter_id)

            drugs = fetch_value(entry, :drugs) || []
            saved_drug_orders = DrugOrderService.create_drug_orders(encounter: encounter, drug_orders: drugs)
            raise "Drug order creation returned empty result" if saved_drug_orders.blank?
            treatment_plan_values.concat(saved_drug_orders.map(&:to_s))

            save_pending_order_obs(encounter, entry)
          end
        rescue StandardError => e
          log_error("Failed to create offline medication order", e)
          collected_errors << "Offline order entry: #{e.message}"
        end
      end

      # Referral sync is handled asynchronously after save in SavePatientRecordService.

      return ok if collected_errors.empty? && orders_unsaved.empty? && pending_orders.empty?

      OperationResult.new(success: true, errors: collected_errors)
    end

    def save_dispensation_data(patient_id, record, order_id = nil, dispensation_data = nil)
      collected_errors = []

      # Standard path
      permitted_data = build_permitted_data(patient_id, record, order_id, dispensation_data)
      permitted_data&.each do |params|
        begin
          process_single_dispensation(params, record)
        rescue StandardError => e
          log_error("Error processing dispensation", e)
          collected_errors << e.message
        end
      end

      # Offline path: art_dispensation_pending — dispensations captured while offline
      pending_dispensations = fetch_value(record, :art_dispensation_pending) || []
      Array.wrap(pending_dispensations).each do |entry|
        next unless entry
        next unless within_session_day?(entry)

        begin
          orders = fetch_value(entry, :orders) || []
          orders.each do |order_entry|
            qty      = fetch_value(order_entry, :quantity).to_i
            drug_ord = DrugOrder.find_by(order_id: fetch_value(order_entry, :order_id))
            next unless drug_ord && qty.positive?

            drug_ord.update!(quantity: qty)
          end
        rescue StandardError => e
          log_error("Failed to process offline dispensation entry", e)
          collected_errors << "Offline dispensation entry: #{e.message}"
        end
      end

      return ok if collected_errors.empty? && (permitted_data.nil? || permitted_data.empty?) && pending_dispensations.empty?

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("Error in save_dispensation_data", e)
    end

    private

    def build_permitted_data(patient_id, record, order_id, dispensation_data)
      if dispensation_data.nil? && order_id.nil?
        extract_unsaved_dispensations(record)
      else
        build_dispensation_payloads(patient_id, order_id, dispensation_data)
      end
    end

    def send_treatment_plan_to_mediator(patient_id, record, treatment_plan_values)
      return unless fetch_value(record, :program_id).to_i == NCD_PROGRAM_ID

      treatment_plan = Array(treatment_plan_values).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      return if treatment_plan.blank?

      FhirService.sendReferralResultsToMediator(
        patient_id,
        treatment_plan: treatment_plan,
        event_id: ichis_referral_event_id(record)
      )
    end

    def ichis_referral_event_id(record)
      direct_event_id = fetch_value(record, :send_ichis_enrolled_in_care_event_id).to_s.strip
      return direct_event_id if direct_event_id.present?

      event_ids = fetch_value(record, :ichisEventIds) || fetch_value(record, :ichis_event_ids)
      Array.wrap(event_ids).map { |event_id| event_id.to_s.strip }.find(&:present?)
    end

    def extract_unsaved_dispensations(record)
      unsaved_data = record.dig(:MedicationOrder, :saved)
      return [] unless unsaved_data&.any?

      unsaved_data.flat_map do |dispensation_params|
        build_dispensation_payloads(nil, nil, fetch_value(dispensation_params, :dispensation))
      end
    end

    def build_dispensation_payloads(patient_id, order_id, dispensation_data)
      return [] if dispensation_data.nil?

      Array.wrap(dispensation_data).compact.map do |dispensation|
        {
          provider_id:   fetch_value(dispensation, :provider_id),
          program_id:    fetch_value(dispensation, :program_id),
          patient_id:    patient_id || fetch_value(dispensation, :patient_id),
          dispensations: [{
            drug_order_id: order_id || fetch_value(dispensation, :drug_order_id),
            date:          fetch_value(dispensation, :date),
            quantity:      fetch_value(dispensation, :quantity)
          }]
        }
      end
    end

    def fetch_value(hash_or_params, key)
      return unless hash_or_params.respond_to?(:[])

      hash_or_params[key] || hash_or_params[key.to_s]
    end

    def process_single_dispensation(params, record)
      dispensations = params[:dispensations]
      program_id    = params[:program_id]
      provider_id   = params[:provider_id]
      return unless dispensations&.any?

      program  = find_program(program_id)
      provider = find_provider(provider_id)
      return unless program && provider

      DispensationService.create(program, dispensations, provider, fetch_value(record, :location_id))
    end

    def find_program(program_id)
      return nil unless program_id
      Program.find(program_id)
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error("Program not found: #{program_id}")
      nil
    end

    def find_provider(provider_id)
      provider_id ? User.find(provider_id).person : User.current&.person
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error("Provider not found: #{provider_id}")
      nil
    end

    # Returns true if the entry's encounter_datetime falls on today's session date.
    # Entries from previous days are skipped — they can no longer be processed.
    def within_session_day?(entry)
      raw = fetch_value(entry, :encounter_datetime)
      return false if raw.blank?

      entry_date = raw.to_s.to_date
      entry_date == Date.today
    rescue ArgumentError, TypeError
      false
    end

    def parse_encounter_datetime(entry)
      raw = fetch_value(entry, :encounter_datetime)
      raw.present? ? raw.to_time : Time.now
    rescue ArgumentError, TypeError
      Time.now
    end

    # Saves regimen-switch and hanging-pills obs from an offline prescription entry
    # onto the already-created TREATMENT encounter.
    def save_pending_order_obs(encounter, entry)
      reason_for_switch = fetch_value(entry, :reasonForSwitch)
      if reason_for_switch.present?
        concept_id = ConceptName.find_by(name: 'Reason for regimen switch')&.concept_id
        if concept_id
          observation_service.create_observation(
            encounter,
            ActionController::Parameters.new(
              concept_id: concept_id,
              value_text: reason_for_switch,
              obs_datetime: encounter.encounter_datetime
            ).permit!
          )
        end
      end

      hanging_pills_status = fetch_value(entry, :hangingPillsStatus)
      if hanging_pills_status.present?
        concept_id = ConceptName.find_by(name: 'Hanging pills')&.concept_id
        if concept_id
          observation_service.create_observation(
            encounter,
            ActionController::Parameters.new(
              concept_id: concept_id,
              value_text: hanging_pills_status,
              obs_datetime: encounter.encounter_datetime
            ).permit!
          )
        end
      end
    end
  end
end
