# app/services/patient_record_service/vaccine_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class VaccineManager < BaseSaver
    def save_vaccines(patient_id, record)
      orders = record.dig(:vaccineAdministration, :orders)
      return false unless orders&.any?

      begin
        ActiveRecord::Base.transaction do
          orders.each do |order|
            encounter_id = create_encounter(patient_id, 25, record)

            obs = record.dig(:vaccineAdministration, :obs)&.find do |item|
              item[:value_text] == order[:drug_name]
            end

            AdministerVaccineService.administer_vaccine(encounter_id, [order], record[:program_id], [obs],
                                                        record[:provider_id], record[:location_id])
          end

          record[:vaccineAdministration][:obs] = []
          record[:vaccineAdministration][:orders] = []
          true
        end
      rescue StandardError => e
        log_error("Failed to save vaccines", e)
      end
    end

    def void_vaccine(_patient_id, record)
      data = record.dig(:vaccineAdministration, :voided)
      return false unless data&.any?

      begin
        ActiveRecord::Base.transaction do
          data.each do |item|
            order = Order.find(item[:order_id])
            order.void(item[:reason])
            Observation.where(order_id: order.id).each { |obs| obs.void(item[:reason]) }
          end
          record[:vaccineAdministration][:voided] = []
          true
        rescue ActiveRecord::RecordNotFound => e
          log_error("Order not found", e)
          record[:vaccineAdministration][:voided] = []
        end
      rescue StandardError => e
        log_error("Error voiding vaccine", e)
      end
    end
  end
end