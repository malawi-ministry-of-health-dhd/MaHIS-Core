# app/services/patient_record_service/dispensation_saver.rb
# frozen_string_literal: true

module PatientRecordService
  class DispensationSaver < BaseSaver
    def save_dispensation_data(patient_id, record)
      unsaved_data = record.dig(:dispensations, :unsaved)
      return ok unless unsaved_data&.any?

      collected_errors = []

      permitted_data = unsaved_data.map do |dispensation_params|
        dispensation_params.permit(
          :operation_id,
          :provider_id,
          :program_id,
          :patient_id,
          dispensations: [:drug_order_id, :date, :quantity]
        )
      end

      permitted_data.each do |params|
        begin
          result = with_operation_guard(
            patient_id: params[:patient_id] || patient_id,
            operation_type: 'dispensation.create',
            operation_id: params[:operation_id],
            payload: params,
            target_type: 'Dispensation'
          ) do
            dispensations = params[:dispensations]
            program_id    = params[:program_id]
            provider_id   = params[:provider_id]

            program  = Program.find(program_id) if program_id
            provider = provider_id ? Person.find(provider_id) : User.current.person

            unless program && dispensations
              collected_errors << "Missing program or dispensations for program_id=#{program_id}"
              next
            end

            DispensationService.create(program, dispensations, provider, record[:location_id])
            {
              target_type: 'Dispensation',
              target_id: Array.wrap(dispensations).map { |item| item[:drug_order_id] }.compact.join(',')
            }
          end

          next if result.skipped?
        rescue ActiveRecord::RecordNotFound => e
          Rails.logger.error("Record not found while processing dispensation: #{e.message}")
          collected_errors << "Record not found: #{e.message}"
        rescue StandardError => e
          Rails.logger.error("Error processing individual dispensation: #{e.message}")
          collected_errors << e.message
        end
      end

      OperationResult.new(success: true, errors: collected_errors)
    rescue StandardError => e
      log_and_fail("Error in save_dispensation_data", e)
    end
  end
end
