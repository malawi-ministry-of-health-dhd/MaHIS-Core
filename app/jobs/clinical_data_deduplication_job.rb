# frozen_string_literal: true

class ClinicalDataDeduplicationJob
  include Sidekiq::Job

  sidekiq_options queue: :clinical_data_cleanup, retry: 2

  def perform(patient_id, options = {})
    env = {
      'PATIENT_IDS' => patient_id.to_s,
      'MODE' => options.fetch('mode', 'clinical').to_s,
      'APPLY' => options['apply'] ? '1' : '0',
      'CONFIRM' => DeduplicatePatientClinicalDataTask::CONFIRMATION,
      'VOIDED_BY' => options['voided_by'].to_s,
      'BATCH_SIZE' => options.fetch('batch_size', 1_000).to_s,
      'ENQUEUE_SYNC' => options.fetch('enqueue_sync', true) ? '1' : '0'
    }

    DeduplicatePatientClinicalDataTask.new(env).run
  end
end
