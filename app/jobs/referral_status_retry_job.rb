# frozen_string_literal: true

class ReferralStatusRetryJob < ApplicationJob
  queue_as :default

  DEFAULT_BATCH_LIMIT = 100
  DEFAULT_LOOKBACK_HOURS = 72

  def perform(batch_limit = DEFAULT_BATCH_LIMIT, lookback_hours = DEFAULT_LOOKBACK_HOURS)
    result = FhirService.retryReferralStatusSyncBatch(
      limit: batch_limit,
      lookback_hours: lookback_hours
    )

    Rails.logger.info(
      "ReferralStatusRetryJob completed: candidates=#{result[:candidates]} attempted=#{result[:attempted]} updated=#{result[:updated]} failed=#{result[:failed]} skipped=#{result[:skipped]}"
    )
    result
  rescue StandardError => e
    Rails.logger.error("ReferralStatusRetryJob failed: #{e.class}: #{e.message}")
    raise
  end
end
