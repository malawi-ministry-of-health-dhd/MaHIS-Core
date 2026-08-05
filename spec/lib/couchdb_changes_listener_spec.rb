# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib', 'couchdb_changes_listener').to_s

RSpec.describe CouchdbChangesListener do
  class CouchdbChangesListenerSpecProcessor
    attr_reader :processed_revisions

    def create_patient_record(doc)
      (@processed_revisions ||= []) << doc[:_rev]
      {
        'ID' => doc[:ID],
        'patientID' => doc[:patientID],
        'labOrders' => {
          'saved' => [{ 'order_id' => 123 }],
          'unsaved' => []
        }
      }
    end
  end

  let(:processor) { CouchdbChangesListenerSpecProcessor.new }
  let(:listener) do
    described_class.new(
      db_name: 'patients_records',
      processor_service: processor,
      processor_method: :create_patient_record,
      couchdb_url: 'http://couchdb.example'
    )
  end

  it 'reprocesses the latest patient document once when the processed update is stale' do
    original_doc = {
      '_id' => 'P123',
      '_rev' => '1-original',
      'ID' => 'P123',
      'patientID' => 77,
      'processed_by_listener' => false
    }
    latest_doc = {
      '_id' => 'P123',
      '_rev' => '2-latest',
      'ID' => 'P123',
      'patientID' => 77,
      'processed_by_listener' => false
    }
    rebuilt_lab_orders = {
      'saved' => [{ 'order_id' => 123 }],
      'unsaved' => []
    }

    allow(listener).to receive(:listener_location_for)
    allow(listener).to receive(:update_couchdb_with_retry).and_return(:stale, true)
    allow(listener).to receive(:fetch_current_document).with('P123').and_return(
      latest_doc,
      latest_doc.merge('_rev' => '3-after-reprocess', 'processed_by_listener' => true)
    )
    allow(BuildPatientRecordService).to receive(:build_lab_orders_data).with(77).and_return(rebuilt_lab_orders)
    allow(listener).to receive(:update_couchdb_document_direct).and_return(true)

    listener.send(:process_document, original_doc)

    expect(processor.processed_revisions).to eq(%w[1-original 2-latest])
    expect(listener).to have_received(:update_couchdb_document_direct).with(
      'P123',
      hash_including('labOrders' => rebuilt_lab_orders)
    )
  end

  it 'skips the processed-marker update when the processor already deleted the document (e.g. a patient void)' do
    class CouchdbChangesListenerSpecDeletingProcessor
      def create_patient_record(_doc)
        { 'ID' => 'P123', 'patientID' => 77, 'deleted_from_couchdb' => true }
      end
    end

    deleting_listener = described_class.new(
      db_name: 'patients_records',
      processor_service: CouchdbChangesListenerSpecDeletingProcessor.new,
      processor_method: :create_patient_record,
      couchdb_url: 'http://couchdb.example'
    )
    allow(deleting_listener).to receive(:listener_location_for)
    allow(deleting_listener).to receive(:update_couchdb_with_retry)

    result = deleting_listener.send(:process_document, {
      '_id' => 'P123',
      '_rev' => '1-original',
      'ID' => 'P123',
      'patientID' => 77,
      'processed_by_listener' => false
    })

    expect(result).to be true
    expect(deleting_listener).not_to have_received(:update_couchdb_with_retry)
  end
end
