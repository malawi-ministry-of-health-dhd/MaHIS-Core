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
end
