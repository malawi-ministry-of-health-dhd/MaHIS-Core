# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sync::BulkPatientRecordSyncJob, type: :job do
  subject(:job) { described_class.new }

  before do
    patient_scope = instance_double(ActiveRecord::Relation, pluck: [123])
    identifier_scope = instance_double(ActiveRecord::Relation, pluck: [[123, 3, 'NPID-123']])

    allow(Patient).to receive(:where).with(patient_id: [123]).and_return(patient_scope)
    allow(PatientIdentifier).to receive(:where).with(patient_id: [123]).and_return(identifier_scope)
    allow(BuildPatientRecordService).to receive(:build_patient_record)
      .with(123)
      .and_return({ ID: 'NPID-123' })
  end

  it 'completes when CouchDB accepts the entire batch' do
    allow(job).to receive(:bulk_sync_patients_to_couchdb).and_return(success: true, errors: [])

    expect { job.perform([123]) }.not_to raise_error
  end

  it 'raises so Sidekiq retries when CouchDB reports a document error' do
    allow(job).to receive(:bulk_sync_patients_to_couchdb)
      .and_return(success: true, errors: ['Doc NPID-123: conflict'])

    expect { job.perform([123]) }
      .to raise_error(/Patient CouchDB bulk sync incomplete/)
  end

  it 'raises so skipped patient IDs are not silently treated as synced' do
    allow(BuildPatientRecordService).to receive(:build_patient_record).with(123).and_return(nil)

    expect { job.perform([123]) }
      .to raise_error(/failed_patients=1/)
  end
end
