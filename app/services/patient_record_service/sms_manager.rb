# app/services/patient_record_service/sms_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class SmsManager < BaseSaver
    def send_sms(_patient_id, record)
      appointment_date = record.dig(:sms, :appointment_date)
      cell_phones      = record.dig(:sms, :cell_phone)
      return ok unless appointment_date && cell_phones&.any?

      collected_errors = []

      cell_phones.each do |phone|
        begin
          enqueue_sms(appointment_date, { cell_phone: phone }, 'send_appointment')
        rescue StandardError => e
          log_error("Failed to queue SMS for phone #{phone}", e)
          collected_errors << "Phone #{phone}: #{e.message}"
        end
      end

      record[:sms][:appointment_date] = ''
      record[:sms][:cell_phone]       = []

      OperationResult.new(success: true, errors: collected_errors)
    end

    private

    def enqueue_sms(date, details, action)
      ImmunizationService::SendSmsService.perform_async(date, details, action)
    end
  end
end