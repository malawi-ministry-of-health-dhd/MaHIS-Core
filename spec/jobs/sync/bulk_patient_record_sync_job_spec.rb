# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sync::BulkPatientRecordSyncJob, type: :job do
  subject(:job) { described_class.new }

  before do
    patient_scope = instance_double(ActiveRecord::Relation, pluck: [123])
    assignment = { current_identifier: 'NPID-123', duplicate_owner_count: 1, pending: false }

    allow(Patient).to receive(:where).with(patient_id: [123]).and_return(patient_scope)
    allow(PatientRecordIdentityService).to receive(:assignment_states).with([123]).and_return(123 => assignment)
    allow(BuildPatientRecordService).to receive(:build_patient_record)
      .with(123, dde_assignment: assignment)
      .and_return({ _id: '4f489184-3ff1-49e0-b642-7fdbba21c818', ID: 'NPID-123' })
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
    allow(BuildPatientRecordService).to receive(:build_patient_record).with(123, dde_assignment: anything).and_return(nil)

    expect { job.perform([123]) }
      .to raise_error(/failed_patients=1/)
  end

  it 'syncs a pending patient without a primary identifier using the permanent record UUID' do
    pending = { current_identifier: '', duplicate_owner_count: 2, pending: true }
    allow(PatientRecordIdentityService).to receive(:assignment_states).with([123]).and_return(123 => pending)
    allow(BuildPatientRecordService).to receive(:build_patient_record)
      .with(123, dde_assignment: pending)
      .and_return({ _id: '4f489184-3ff1-49e0-b642-7fdbba21c818', ID: '', identifierAssignmentStatus: 'pending' })
    allow(job).to receive(:bulk_sync_patients_to_couchdb).and_return(success: true, errors: [])

    expect { job.perform([123]) }.not_to raise_error
  end

  it 'does not reject a patient based on observation or order counts' do
    allow(job).to receive(:bulk_sync_patients_to_couchdb).and_return(success: true, errors: [])
    expect(Observation).not_to receive(:unscoped)
    expect(Order).not_to receive(:unscoped)

    expect { job.perform([123]) }.not_to raise_error
  end
end
