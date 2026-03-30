# app/services/patient_record_service/medication_order_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class MedicationOrderSaver < BaseSaver
    ENCOUNTER_TYPE_MAPPING = SavePatientRecordService::ENCOUNTER_TYPE_MAPPING

    def save_medication_order(patient_id, record)
      orders_unsaved = record.dig(:MedicationOrder, :unsaved)
      return ok unless orders_unsaved&.any?

      collected_errors = []

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

            dispensation_result = save_dispensation_data(patient_id, record, saved_drug_orders[0].order_id, order[:dispensation])
            collected_errors.concat(dispensation_result.errors) if dispensation_result.errors.any?
          end
        rescue StandardError => e
          log_error("Failed to create medication order", e)
          collected_errors << "Order #{order.inspect}: #{e.message}"
          # continues to next order
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    end

    def save_dispensation_data(patient_id, record, order_id = nil, dispensation_data = nil)
      permitted_data = build_permitted_data(patient_id, record, order_id, dispensation_data)
      return ok unless permitted_data&.any?

      collected_errors = []

      permitted_data.each do |params|
        begin
          process_single_dispensation(params, record)
        rescue StandardError => e
          log_error("Error processing dispensation", e)
          collected_errors << e.message
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("Error in save_dispensation_data", e)
    end

    private

    def build_permitted_data(patient_id, record, order_id, dispensation_data)
      if dispensation_data.nil? && order_id.nil?
        extract_unsaved_dispensations(record)
      else
        build_single_dispensation(patient_id, order_id, dispensation_data)
      end
    end

    def extract_unsaved_dispensations(record)
      unsaved_data = record.dig(:MedicationOrder, :saved)
      return [] unless unsaved_data&.any?

      unsaved_data.flat_map do |dispensation_params|
        next [] unless dispensation_params[:dispensation]

        dispensation_params[:dispensation].map do |dispensation|
          {
            provider_id:   dispensation[:provider_id],
            program_id:    dispensation[:program_id],
            patient_id:    dispensation[:patient_id],
            dispensations: [{
              drug_order_id: dispensation[:drug_order_id],
              date:          dispensation[:date],
              quantity:      dispensation[:quantity]
            }]
          }
        end
      end
    end

    def build_single_dispensation(patient_id, order_id, dispensation_data)
      return [] if dispensation_data.nil?

      [{
        provider_id:   dispensation_data[:provider_id],
        program_id:    dispensation_data[:program_id],
        patient_id:    patient_id,
        dispensations: [{
          drug_order_id: order_id,
          date:          dispensation_data[:date],
          quantity:      dispensation_data[:quantity]
        }]
      }]
    end

    def process_single_dispensation(params, record)
      dispensations = params[:dispensations]
      program_id    = params[:program_id]
      provider_id   = params[:provider_id]
      return unless dispensations&.any?

      program  = find_program(program_id)
      provider = find_provider(provider_id)
      return unless program && provider

      DispensationService.create(program, dispensations, provider, record[:location_id])
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
  end
end