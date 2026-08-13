# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sync::BatchPatientSyncJob, type: :job do
  describe '.recent_since_date' do
    it 'returns a non-blank String (a JSON-native type Sidekiq strict args accepts)' do
      result = described_class.recent_since_date

      expect(result).to be_a(String)
      expect(result).to be_present
    end

    it 'returns a value parseable by parse_since_date (Time.zone.parse)' do
      result = described_class.recent_since_date

      expect { Time.zone.parse(result) }.not_to raise_error
      expect(Time.zone.parse(result)).to be_a(ActiveSupport::TimeWithZone)
    end

    it 'points to roughly the configured lookback window in the past' do
      parsed = Time.zone.parse(described_class.recent_since_date)

      expect(parsed).to be_within(5.seconds).of(described_class::RECENT_SYNC_LOOKBACK.ago)
    end

    it 'is in the past but recent enough to capture a just-saved encounter' do
      parsed = Time.zone.parse(described_class.recent_since_date)

      expect(parsed).to be < Time.current
      expect(parsed).to be > 2.days.ago
    end
  end

  describe '#perform' do
    subject(:job) { described_class.new }

    before do
      allow(job).to receive(:initialize_patient_progress)
      allow(Sync::EnsurePatientIndexesJob).to receive(:perform_async)
    end

    it 'bypasses the incremental watermark and scans every patient when force_full is true' do
      expect(job).not_to receive(:default_since_date)
      expect(job).to receive(:sync_patients_in_bulk)
        .with(nil, nil, described_class::DEFAULT_BATCH_SIZE)
        .and_return([0, 0])

      job.perform(nil, nil, described_class::DEFAULT_BATCH_SIZE, true)

      expect(Sync::EnsurePatientIndexesJob).to have_received(:perform_async)
        .with('reconcile' => true)
    end

    it 'enqueues only missing patient documents by default' do
      result = PatientSyncReconciler::Result.new(missing_reenqueued: 25_666, errored: false)
      allow(PatientSyncReconciler).to receive(:reconcile!).and_return(result)
      expect(job).not_to receive(:sync_patients_in_bulk)

      job.perform

      expect(PatientSyncReconciler).to have_received(:reconcile!).with(logger: Sidekiq.logger)
      expect(Sync::EnsurePatientIndexesJob).to have_received(:perform_async)
        .with('reconcile' => true)
    end

    it 'retries when the missing-document scan cannot reach CouchDB' do
      result = PatientSyncReconciler::Result.new(missing_reenqueued: 0, errored: true)
      allow(PatientSyncReconciler).to receive(:reconcile!).and_return(result)

      expect { job.perform }
        .to raise_error('Missing-only patient reconciliation failed; retrying')
    end

    it 'retains incremental behavior when an explicit watermark is provided' do
      watermark = '2026-01-01T00:00:00Z'
      parsed_watermark = Time.zone.parse(watermark)

      expect(job).not_to receive(:default_since_date)
      expect(job).to receive(:sync_patients_in_bulk)
        .with(nil, parsed_watermark, described_class::DEFAULT_BATCH_SIZE)
        .and_return([0, 0])

      job.perform(nil, watermark)
    end

  end

  describe 'patient eligibility and progress' do
    subject(:job) { described_class.new }

    it 'uses UUID-addressable patients as the achievable progress total' do
      allow(PatientSyncReconciler).to receive(:syncable_patient_count).and_return(128_825)
      allow(CouchdbPatientService).to receive(:patient_record_count).and_return(103_546)
      allow(SyncProgress).to receive(:start)
      allow(SyncProgress).to receive(:set)

      job.send(:initialize_patient_progress)

      expect(SyncProgress).to have_received(:start).with('patients_records', 128_825)
      expect(SyncProgress).to have_received(:set).with('patients_records', 103_546)
    end

    it 'builds full-sync batches from eligible patient IDs only' do
      eligible_ids = instance_double(ActiveRecord::Relation)
      scope = instance_double(ActiveRecord::Relation)

      allow(PatientSyncReconciler).to receive(:eligible_patient_ids).and_return(eligible_ids)
      expect(Patient).to receive(:where).with(patient_id: eligible_ids).and_return(scope)
      expect(scope).to receive(:where).with('patient.patient_id > ?', 100).and_return(scope)
      expect(scope).to receive(:reorder).with(nil).and_return(scope)
      expect(scope).to receive(:order).with(patient_id: :asc).and_return(scope)
      expect(scope).to receive(:limit).with(1_000).and_return(scope)
      expect(scope).to receive(:pluck).with(:patient_id).and_return([101, 102])

      expect(job.send(:next_patient_batch, 100, 1_000)).to eq([101, 102])
    end
  end
end
