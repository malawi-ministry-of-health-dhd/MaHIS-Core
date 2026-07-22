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

    it 'retains the incremental watermark behavior by default' do
      watermark = '2026-01-01T00:00:00Z'
      parsed_watermark = Time.zone.parse(watermark)

      expect(job).to receive(:default_since_date).with(nil).and_return(watermark)
      expect(job).to receive(:sync_patients_in_bulk)
        .with(nil, parsed_watermark, described_class::DEFAULT_BATCH_SIZE)
        .and_return([0, 0])

      job.perform
    end

  end
end
