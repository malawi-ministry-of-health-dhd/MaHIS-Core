# app/services/patient_record_service/operation_result.rb
# frozen_string_literal: true

module PatientRecordService
  class OperationResult
    attr_reader :success, :errors

    def initialize(success:, errors: [])
      @errors  = Array(errors).compact
      @success = success && @errors.empty?
    end

    def success? = @success
    def failed?  = !@success

    def self.ok
      new(success: true)
    end

    def self.fail(*errors)
      new(success: false, errors: errors.flatten)
    end
  end
end
