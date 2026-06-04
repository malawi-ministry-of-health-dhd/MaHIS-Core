# app/services/patient_record_service/operation_result.rb
# frozen_string_literal: true

module PatientRecordService
  class OperationResult
    attr_reader :success, :errors

    def initialize(success:, errors: [], changed: nil)
      @errors  = Array(errors).compact
      @success = success && @errors.empty?
      @changed = @success && (changed.nil? ? true : !!changed)
    end

    def success? = @success
    def failed?  = !@success
    def changed? = @changed

    def self.ok(changed: false)
      new(success: true, changed: changed)
    end

    def self.fail(*errors)
      new(success: false, errors: errors.flatten, changed: false)
    end
  end
end
