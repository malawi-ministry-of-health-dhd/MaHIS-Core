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

      results = service.ensure_pool_for_all_facilities(target_count: TARGET_COUNT)
      Sidekiq.logger.info("Lab accession number pool top-up completed: #{results.inspect}")
      results
    end
  end
end
