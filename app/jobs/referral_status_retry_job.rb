# frozen_string_literal: true

class ReferralStatusRetryJob
  include Sidekiq::Job
  sidekiq_options queue: 'default', retry: 10

  DEFAULT_BATCH_LIMIT = 100
  DEFAULT_LOOKBACK_HOURS = 720

  def perform(batch_limit = DEFAULT_BATCH_LIMIT, lookback_hours = DEFAULT_LOOKBACK_HOURS)
    result = FhirService.retryReferralStatusSyncBatch(
      limit: batch_limit,
      lookback_hours: lookback_hours
    )

    Sidekiq.logger.info(
      "ReferralStatusRetryJob completed: candidates=#{result[:candidates]} attempted=#{result[:attempted]} updated=#{result[:updated]} failed=#{result[:failed]} skipped=#{result[:skipped]}"
    )
    result
  rescue StandardError => e
    Sidekiq.logger.error("ReferralStatusRetryJob failed: #{e.class}: #{e.message}")
    raise
  end
end
