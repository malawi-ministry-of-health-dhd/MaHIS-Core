# app/services/patient_record_service/void_patient.rb
# frozen_string_literal: true

module PatientRecordService
  class VoidPatient < BaseSaver
    def void_patient(patient_id, record)
      void_request = operation_value_for(record, :void_patient)
      return ok if void_request.blank?

      reason = operation_value_for(void_request, :reason).to_s.strip
      return fail('Missing reason for void_patient request') if reason.blank?

      patient = Patient.unscoped.find(patient_id)
      return ok if patient.voided?

      result = with_operation_guard(
        patient_id: patient_id,
        operation_type: 'patient.void',
        payload: void_request,
        target_type: 'Patient'
      ) do
        patient_service.void_patient(patient, reason, daemonize: false)
        { target_type: 'Patient', target_id: patient_id }
      end

      return ok if result.skipped?

      changed_ok
    rescue ActiveRecord::RecordNotFound => e
      fail("Patient #{patient_id} not found: #{e.message}")
    rescue StandardError => e
      log_and_fail('VoidPatient#void_patient', e)
    end

    private

    def patient_service
      @patient_service ||= PatientService.new
    end
  end
end
