# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ClinicalDataDeduplicationJob, type: :job do
  subject(:job) { described_class.new }

  it 'runs one patient cleanup with JSON-safe Sidekiq options' do
    cleanup = instance_double(DeduplicatePatientClinicalDataTask, run: nil)
    allow(DeduplicatePatientClinicalDataTask).to receive(:new).and_return(cleanup)

    job.perform(
      149_550,
      {
        'mode' => 'replay',
        'apply' => true,
        'voided_by' => 1,
        'batch_size' => 500,
        'enqueue_sync' => true
      }
    )

    expect(DeduplicatePatientClinicalDataTask).to have_received(:new).with(
      'PATIENT_IDS' => '149550',
      'MODE' => 'replay',
      'APPLY' => '1',
      'CONFIRM' => 'VOID_DUPLICATES',
      'VOIDED_BY' => '1',
      'BATCH_SIZE' => '500',
      'ENQUEUE_SYNC' => '1'
    )
    expect(cleanup).to have_received(:run)
  end

  it 'uses the dedicated cleanup queue' do
    expect(described_class.get_sidekiq_options['queue'].to_s).to eq('clinical_data_cleanup')
  end

  it 'enqueues one JSON-safe job argument set per patient' do
    patient_scope = instance_double(ActiveRecord::Relation, exists?: true)
    allow(Patient).to receive(:unscoped).and_return(patient_scope)
    allow(described_class).to receive(:perform_bulk).and_return(%w[jid-1 jid-2])

    cleanup = DeduplicatePatientClinicalDataTask.new(
      'PATIENT_IDS' => '149550,149564',
      'MODE' => 'replay',
      'APPLY' => '1',
      'CONFIRM' => 'VOID_DUPLICATES',
      'VOIDED_BY' => '1',
      'BATCH_SIZE' => '500'
    )
    cleanup.enqueue

    options = {
      'mode' => 'replay',
      'apply' => true,
      'voided_by' => 1,
      'batch_size' => 500,
      'enqueue_sync' => true
    }
    expect(described_class).to have_received(:perform_bulk).with(
      [
        [149_550, options],
        [149_564, options]
      ]
    )
  end
end

RSpec.describe DeduplicatePatientClinicalDataTask do
  it 'uses temporary mapping tables and joined updates for the write phase' do
    task = described_class.allocate
    task.instance_variable_set(:@batch_size, 1_000)
    task.instance_variable_set(:@voided_by, 1)
    plan = described_class::Plan.new(
      patient_id: 149_550,
      order_duplicate_to_keeper: { 102 => 101 },
      observation_duplicate_to_keeper: { 202 => 201 },
      order_groups: 1,
      observation_groups: 1
    )
    connection = double('connection')
    statements = []

    allow(connection).to receive(:quote_table_name) { |name| "`#{name}`" }
    allow(connection).to receive(:quote_column_name) { |name| "`#{name}`" }
    allow(connection).to receive(:quote) { |value| "'#{value}'" }
    allow(connection).to receive(:execute) do |sql|
      statements << sql.to_s.squish
    end
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    allow(ActiveRecord::Base).to receive(:transaction).and_yield

    task.send(:apply_plan, plan)

    expect(statements.grep(/CREATE TEMPORARY TABLE/).size).to eq(2)
    expect(statements.grep(/INNER JOIN/).size).to eq(5)
    expect(statements.grep(/SET target\.voided = 1/).size).to eq(2)
    expect(statements.join(' ')).not_to include('CASE')
  end
end
