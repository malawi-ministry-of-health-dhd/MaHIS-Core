# frozen_string_literal: true

module Sync
  class LabAccessionNumberSyncJob < BaseSyncJob
    CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml'))) || {}
    configured_target_count = CONFIG['LAB_ACCESSION_TARGET_COUNT'].to_i
    TARGET_COUNT = configured_target_count.positive? ? configured_target_count : LabAccessionNumberPoolService::DEFAULT_TARGET_COUNT

    def perform(_batch_size = DEFAULT_BULK_BATCH_SIZE, location_id = nil)
      service = LabAccessionNumberPoolService.new

      if location_id.present?
        result = service.ensure_pool_for_location(location_id: location_id, target_count: TARGET_COUNT)
        Sidekiq.logger.info("Lab accession number pool top-up result for location #{location_id}: #{result.inspect}")
        return result
      end

      # Register a progress row so the sync dashboard always shows this job. The
      # pool top-up doesn't stream a dataset, so report it as a single unit of
      # work sized by the number of facilities processed.
      progress_key = 'lab_accession_numbers'
      SyncProgress.start(progress_key, 0)

      begin
        results = service.ensure_pool_for_all_facilities(target_count: TARGET_COUNT)
        SyncProgress.ensure(progress_key, results.length)
        SyncProgress.finish(progress_key)
        Sidekiq.logger.info("Lab accession number pool top-up completed: #{results.inspect}")
        results
      rescue StandardError => e
        SyncProgress.fail(progress_key, e.message)
        raise
      end
    end
  end
end
