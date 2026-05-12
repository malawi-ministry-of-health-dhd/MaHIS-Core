# frozen_string_literal: true

class ReferralStatusSyncJob
  include Sidekiq::Job
  sidekiq_options queue: 'default', retry: 10

  def perform(patient_id, tei = nil, event_id = nil)
    sync_result = FhirService.syncReferralStatusForPatient(
      patient_id: patient_id,
      tei: tei,
      event_id: event_id
    )

    Sidekiq.logger.info(
      "ReferralStatusSyncJob completed for patient=#{patient_id} " \
      "identifier_status=#{sync_result.dig(:identifier_sync, :status)} " \
      "referral_status=#{sync_result.dig(:referral_sync, :status)} " \
      "event_id=#{sync_result[:event_id]}"
    )

    sync_result
  rescue StandardError => e
    Sidekiq.logger.error("ReferralStatusSyncJob failed for patient=#{patient_id}: #{e.class}: #{e.message}")
    raise
  end
end
