# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sync::MnhStatsSyncJob do
  describe '.enqueue_date_refresh' do
    it 'does not enqueue stats for a facility without DDE activation' do
      allow(described_class).to receive(:dde_activated_location?).with(42).and_return(false)

      expect(described_class).not_to receive(:perform_async)

      described_class.enqueue_date_refresh(42, 'anc', Date.new(2026, 7, 28))
    end

    it 'enqueues stats for a DDE-activated facility' do
      allow(described_class).to receive(:dde_activated_location?).with(42).and_return(true)

      expect(described_class).to receive(:perform_async)
        .with('2026-07-28', described_class::DEFAULT_BULK_BATCH_SIZE, '42', 'anc')

      described_class.enqueue_date_refresh(42, 'anc', Date.new(2026, 7, 28))
    end
  end

  describe '#perform' do
    subject(:job) { described_class.new }

    before do
      allow(job).to receive(:couchdb_configured?).and_return(true)
    end

    it 'does not calculate stats for a facility without DDE activation' do
      allow(job).to receive(:dde_activated_location?).with('42').and_return(false)

      expect(job).not_to receive(:build_stats_rows)

      job.perform(nil, 5000, '42')
    end

    it 'dispatches jobs only to DDE-activated facilities' do
      allow(job).to receive(:dde_activated_location_ids).and_return(%w[42 84])

      expect(described_class).to receive(:perform_async).with(nil, 5000, '42', nil).ordered
      expect(described_class).to receive(:perform_async).with(nil, 5000, '84', nil).ordered

      job.perform
    end
  end

  describe '#fetch_dde_activated_location_ids' do
    subject(:job) { described_class.new }

    it 'returns only activated facilities and supports facility ids encoded in _id' do
      response = instance_double(
        RestClient::Response,
        body: {
          docs: [
            { _id: 'facility_42', location_id: 42, dde_activated: true },
            { _id: 'facility_84', dde_activated: 'true' },
            { _id: 'facility_126', location_id: 126, dde_activated: false }
          ]
        }.to_json
      )
      allow(job).to receive(:couchdb_url).with('facilities').and_return('http://couchdb/facilities')
      allow(RestClient).to receive(:post).and_return(response)

      expect(job.send(:fetch_dde_activated_location_ids)).to contain_exactly('42', '84')
    end
  end
end
