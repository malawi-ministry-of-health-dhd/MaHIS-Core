# frozen_string_literal: true

require 'digest'
require 'json'

class PatientRecordOperationGuard
  Result = Struct.new(:state, :value, :receipt, keyword_init: true) do
    def skipped?
      state == :skipped
    end

    def processed?
      state == :processed
    end
  end

  OPERATION_ID_KEYS = %i[
    operation_id client_operation_id offline_id sync_operation_id uuid _id id
  ].freeze

  VOLATILE_PAYLOAD_KEYS = %w[
    _rev processed_by_listener listener_retry_count listener_last_error
    listener_failed_at listener_dead_letter listener_processed_at processed_by_db
    operation_errors
  ].freeze
  PROCESSING_WAIT_TIMEOUT = 15.seconds
  PROCESSING_WAIT_INTERVAL = 0.25.seconds

  class << self
    def run!(patient_id:, operation_type:, operation_id: nil, payload: nil, target_type: nil)
      resolved_operation_id = normalize_operation_id(operation_id.presence || operation_id_from_payload(payload))
      resolved_payload_hash = payload_hash(payload)

      receipt, should_process = claim_receipt(
        patient_id: patient_id,
        operation_type: operation_type,
        operation_id: resolved_operation_id,
        payload_hash: resolved_payload_hash
      )

      unless should_process
        Rails.logger.info(
          "[PatientRecordOperationGuard] Skipping duplicate #{operation_type} operation_id=#{resolved_operation_id}"
        )
        return Result.new(state: :skipped, value: nil, receipt: receipt)
      end

      begin
        value = yield(receipt)
        complete_receipt!(receipt, value, target_type)
        Result.new(state: :processed, value: value, receipt: receipt)
      rescue StandardError => e
        fail_receipt!(receipt, e)
        raise
      end
    end

    def operation_id_from_payload(payload)
      OPERATION_ID_KEYS.each do |key|
        value = value_for(payload, key)
        return value if value.present?
      end

      "sha256:#{payload_hash(payload)}"
    end

    def payload_hash(payload)
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))
    end

    private

    def claim_receipt(patient_id:, operation_type:, operation_id:, payload_hash:)
      now = Time.current

      receipt = PatientRecordOperationReceipt.create!(
        patient_id: patient_id,
        operation_type: operation_type,
        operation_id: operation_id,
        payload_hash: payload_hash,
        status: 'processing',
        started_at: now
      )

      [receipt, true]
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise unless duplicate_receipt_error?(e)

      existing_receipt = PatientRecordOperationReceipt.find_by!(
        operation_type: operation_type,
        operation_id: operation_id
      )

      if existing_receipt.processing?
        existing_receipt = wait_for_processing_receipt(existing_receipt)
        return [existing_receipt, false] if existing_receipt.completed? || existing_receipt.processing?
      end

      PatientRecordOperationReceipt.transaction do
        receipt = PatientRecordOperationReceipt.lock.find_by!(
          operation_type: operation_type,
          operation_id: operation_id
        )

        if receipt.payload_hash.present? && payload_hash.present? && receipt.payload_hash != payload_hash
          Rails.logger.warn(
            "[PatientRecordOperationGuard] operation_id=#{operation_id} reused for #{operation_type} with a different payload hash"
          )
        end

        should_process = !(receipt.completed? || receipt.processing?)

        if should_process
          receipt.update!(
            patient_id: patient_id || receipt.patient_id,
            payload_hash: payload_hash,
            status: 'processing',
            error_message: nil,
            started_at: now,
            completed_at: nil
          )
        end

        [receipt, should_process]
      end
    end

    def wait_for_processing_receipt(receipt)
      deadline = Time.current + PROCESSING_WAIT_TIMEOUT

      while receipt.processing? && Time.current < deadline
        sleep(PROCESSING_WAIT_INTERVAL)
        receipt.reload
      end

      receipt
    rescue ActiveRecord::RecordNotFound
      receipt
    end

    def duplicate_receipt_error?(error)
      return true if error.is_a?(ActiveRecord::RecordNotUnique)

      error.is_a?(ActiveRecord::RecordInvalid) &&
        error.record.is_a?(PatientRecordOperationReceipt) &&
        error.record.errors.details[:operation_id].any? { |detail| detail[:error] == :taken }
    end

    def complete_receipt!(receipt, value, default_target_type)
      target_type, target_id = target_reference(value, default_target_type)

      receipt.update!(
        status: 'completed',
        target_type: target_type,
        target_id: target_id,
        error_message: nil,
        completed_at: Time.current
      )
    end

    def fail_receipt!(receipt, error)
      receipt.update!(
        status: 'failed',
        error_message: error.message.to_s.truncate(65_000)
      )
    rescue StandardError => e
      Rails.logger.error(
        "[PatientRecordOperationGuard] Failed to mark operation #{receipt&.operation_type}/#{receipt&.operation_id} failed: #{e.message}"
      )
    end

    def target_reference(value, default_target_type)
      if value.respond_to?(:attributes)
        return [value.class.name, value.try(:id) || value.try(:order_id) || value.try(:encounter_id)]
      end

      return [default_target_type, nil] unless value.respond_to?(:[])

      target_type = value[:target_type] || value['target_type'] || default_target_type
      target_id = value[:target_id] || value['target_id'] || value[:id] || value['id'] ||
                  value[:order_id] || value['order_id'] || value[:drug_order_id] || value['drug_order_id'] ||
                  value[:encounter_id] || value['encounter_id'] || value[:visit_id] || value['visit_id'] ||
                  value[:patient_program_id] || value['patient_program_id']

      [target_type, target_id]
    end

    def normalize_operation_id(value)
      normalized = value.to_s.strip
      return normalized.first(191) if normalized.present?

      raise ArgumentError, 'operation_id is required'
    end

    def canonicalize(value)
      case value
      when ActionController::Parameters
        canonicalize(value.to_unsafe_h)
      when Hash
        value.each_with_object({}) do |(key, nested_value), hash|
          string_key = key.to_s
          next if VOLATILE_PAYLOAD_KEYS.include?(string_key)

          hash[string_key] = canonicalize(nested_value)
        end.sort.to_h
      when Array
        value.map { |nested_value| canonicalize(nested_value) }
      when Time, DateTime
        value.iso8601
      when Date
        value.to_s
      else
        value
      end
    end

    def value_for(container, key)
      return nil if container.nil? || !container.respond_to?(:[])

      container[key] || container[key.to_s]
    rescue TypeError
      nil
    end
  end
end
