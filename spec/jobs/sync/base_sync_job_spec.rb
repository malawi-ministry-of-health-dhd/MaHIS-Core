# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sync::BaseSyncJob, type: :job do
  subject(:job) { described_class.new }

  describe '#post_bulk_docs' do
    let(:bulk_url) { 'http://couch.test/patients_records/_bulk_docs' }

    before do
      allow(job).to receive(:max_bulk_request_bytes).and_return(100)
      allow(job).to receive(:max_document_bytes).and_return(80)
    end

    it 'splits a request that is too large while preserving successful results' do
      documents = [
        { '_id' => 'one', 'data' => 'a' * 35 },
        { '_id' => 'two', 'data' => 'b' * 35 }
      ]
      allow(RestClient).to receive(:post) do |_url, payload, _headers|
        ids = JSON.parse(payload).fetch('docs').map { |doc| doc.fetch('_id') }
        instance_double(RestClient::Response, body: ids.map { |id| { id: id, ok: true } }.to_json)
      end

      result = job.send(:post_bulk_docs, documents, bulk_url)

      expect(result).to eq(success: true, errors: [], conflicts: [])
      expect(RestClient).to have_received(:post).twice
    end

    it 'does not send a single oversized document to CouchDB' do
      document = { '_id' => 'huge', 'data' => 'x' * 100 }
      allow(RestClient).to receive(:post)

      result = job.send(:post_bulk_docs, [document], bulk_url)

      expect(result[:success]).to be(false)
      expect(result[:errors].first).to include('Doc huge: document_too_large')
      expect(RestClient).not_to have_received(:post)
    end
  end
end
