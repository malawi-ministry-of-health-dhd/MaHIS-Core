# app/services/patient_record_service/sms_manager.rb
# frozen_string_literal: true

module PatientRecordService
  class SmsManager < BaseSaver
    def send_sms(_patient_id, record)
      appointment_date = record.dig('sms', 'appointment_date')
      cell_phones = record.dig('sms', 'cell_phone')
      return false unless appointment_date && cell_phones

      cell_phones.map do |phone|
        patient_details = { cell_phone: phone }
        enqueue_sms(appointment_date, patient_details, 'send_appointment')
      end
      record[:sms][:appointment_date] = ''
      record[:sms][:cell_phone] = []
      true
    end

    def enqueue_sms(date, details, action)
      ImmunizationService::SendSmsService.perform_async(date, details, action)
    rescue StandardError => e
      log_error("Failed to queue SMS", e)
    end
  end
end