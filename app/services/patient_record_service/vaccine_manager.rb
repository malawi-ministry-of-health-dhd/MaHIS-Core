# app/services/patient_record_service/vaccine_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class VaccineManager < BaseSaver
    def save_vaccines(patient_id, record)
      orders = record.dig(:vaccineAdministration, :orders)
      return ok unless orders&.any?

      collected_errors = []

      orders.each do |order|
        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            encounter_id = create_encounter(patient_id, 25, record)

            obs = record.dig(:vaccineAdministration, :obs)&.find do |item|
              item[:value_text] == order[:drug_name]
            end

            AdministerVaccineService.administer_vaccine(
              encounter_id, [order], record[:program_id], [obs],
              record[:provider_id], record[:location_id]
            )
          end
        rescue StandardError => e
          log_error("Failed to save vaccine order #{order[:drug_name]}", e)
          collected_errors << "Vaccine #{order[:drug_name]}: #{e.message}"
          # continues to next order
        end
      end

      record[:vaccineAdministration][:obs]    = []
      record[:vaccineAdministration][:orders] = []

      OperationResult.new(success: true, errors: collected_errors)
    end

    def void_vaccine(_patient_id, record)
      data = record.dig(:vaccineAdministration, :voided)
      return ok unless data&.any?

      collected_errors = []

      data.each do |item|
        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            order = Order.find(item[:order_id])
            order.void(item[:reason])
            Observation.where(order_id: order.id).each { |obs| obs.void(item[:reason]) }
          end
        rescue ActiveRecord::RecordNotFound => e
          log_error("Order not found for void", e)
          collected_errors << "Order #{item[:order_id]}: #{e.message}"
        rescue StandardError => e
          log_error("Error voiding vaccine", e)
          collected_errors << "Order #{item[:order_id]}: #{e.message}"
        end
      end

      record[:vaccineAdministration][:voided] = []
      OperationResult.new(success: true, errors: collected_errors)
    end
  end
end