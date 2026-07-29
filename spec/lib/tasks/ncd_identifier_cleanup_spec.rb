# frozen_string_literal: true

require 'rails_helper'
require 'rake'

load Rails.root.join('lib/tasks/ncd_identifier_cleanup.rake')

RSpec.describe NcdIdentifierCleanupTask do
  def build_task(collision_mode: 'next')
    described_class.new(
      database_name: 'NDC_mahis',
      identifier_type: 31,
      mapping_path: Rails.root.join('db/ncd_facility_prefix_mapping.json'),
      details_path: Rails.root.join('tmp/ncd_identifier_cleanup_test_details.json'),
      review_path: Rails.root.join('tmp/ncd_identifier_cleanup_test_review.json'),
      dry_run: true,
      collision_mode: collision_mode,
      max_next_number_source: 100_000
    )
  end

  def active_row(id:, patient_id:, identifier:, facility_name: 'Unmapped Clinic')
    {
      'patient_identifier_id' => id,
      'patient_id' => patient_id,
      'identifier' => identifier,
      'identifier_location_id' => 10,
      'date_created' => Time.zone.parse('2024-01-01'),
      'creator' => 1,
      'user_location_id' => '10',
      'facility_name' => facility_name,
      'matched_facility_code' => 'TEST'
    }
  end

  def reservation(row, voided: 0)
    row.slice(
      'patient_identifier_id',
      'patient_id',
      'identifier',
      'identifier_location_id'
    ).merge('voided' => voided)
  end

  def cleanup_plan(task, active_rows:, reservations:, mapping: {})
    allow(task).to receive(:all_identifier_rows).and_return(active_rows)
    allow(task).to receive(:all_identifier_reservation_rows).and_return(reservations)
    allow(task).to receive(:load_json_hash).and_return(mapping)
    task.send(:build_cleanup_plan)
  end

  def facility_row(id:, patient_id:, identifier:, active_ncd_count: nil)
    {
      'patient_identifier_id' => id,
      'patient_id' => patient_id,
      'identifier' => identifier,
      'identifier_location_id' => id ? 568 : nil,
      'date_created' => id ? Time.zone.parse('2024-01-01') : nil,
      'creator' => id ? 2 : nil,
      'program_creator' => 2,
      'user_location_id' => 568,
      'facility_name' => 'Program location 568',
      'matched_facility_code' => nil,
      'active_ncd_count' => active_ncd_count.nil? ? (id ? 1 : 0) : active_ncd_count
    }
  end

  def facility_cleanup_plan(task, rows:, reservations:)
    allow(task).to receive(:facility_program_rows).with(568).and_return(rows)
    allow(task).to receive(:all_identifier_reservation_rows).and_return(reservations)
    task.send(:build_facility_cleanup_plan, 568, 'KDH', 1)
  end

  it 'reserves voided NCD numbers when repairing an active identifier' do
    task = build_task
    active = active_row(id: 2, patient_id: 20, identifier: 'ABC - NCD - 1')
    voided = active_row(id: 1, patient_id: 10, identifier: 'ABC-NCD-1')

    plan = cleanup_plan(
      task,
      active_rows: [active],
      reservations: [reservation(voided, voided: 1), reservation(active)]
    )

    expect(plan[:changes]).to contain_exactly(
      hash_including(
        patient_identifier_id: 2,
        old_identifier: 'ABC - NCD - 1',
        new_identifier: 'ABC-NCD-2',
        category: 'spacing_collision_next_number'
      )
    )
  end

  it 'allows a patient to retain a number found only in that same patient’s voided history' do
    task = build_task
    active = active_row(id: 2, patient_id: 10, identifier: 'ABC-NCD-1')
    voided = active_row(id: 1, patient_id: 10, identifier: 'ABC-NCD-1')

    plan = cleanup_plan(
      task,
      active_rows: [active],
      reservations: [reservation(voided, voided: 1), reservation(active)]
    )

    expect(plan[:changes]).to be_empty
    expect(plan[:unresolved]).to be_empty
  end

  it 'keeps the first standard duplicate and gives a later patient the next unused number' do
    task = build_task
    first = active_row(id: 1, patient_id: 10, identifier: 'ABC-NCD-1')
    second = active_row(id: 2, patient_id: 20, identifier: 'ABC-NCD-1')

    plan = cleanup_plan(
      task,
      active_rows: [first, second],
      reservations: [reservation(first), reservation(second)]
    )

    expect(plan[:changes]).to contain_exactly(
      hash_including(
        patient_identifier_id: 2,
        old_identifier: 'ABC-NCD-1',
        new_identifier: 'ABC-NCD-2',
        category: 'duplicate_identifier_next_number'
      )
    )
    expect(plan[:unresolved]).to be_empty
  end

  it 'does not give one patient a second number when duplicate rows belong to that patient' do
    task = build_task
    first = active_row(id: 1, patient_id: 10, identifier: 'ABC-NCD-1')
    second = active_row(id: 2, patient_id: 10, identifier: 'ABC-NCD-1')

    plan = cleanup_plan(
      task,
      active_rows: [first, second],
      reservations: [reservation(first), reservation(second)]
    )

    expect(plan[:changes]).to be_empty
    expect(plan[:unresolved]).to contain_exactly(
      hash_including(
        patient_identifier_id: 2,
        reason: 'same patient has duplicate active NCD identifier rows'
      )
    )
  end

  it 'uses a reviewed facility mapping for undefined prefixes' do
    task = build_task
    active = active_row(
      id: 1,
      patient_id: 10,
      identifier: 'undefined-NCD-23',
      facility_name: 'Mapped Clinic'
    )

    plan = cleanup_plan(
      task,
      active_rows: [active],
      reservations: [reservation(active)],
      mapping: { 'Mapped Clinic' => { 'ncd_prefix' => 'abc' } }
    )

    expect(plan[:changes]).to contain_exactly(
      hash_including(
        patient_identifier_id: 1,
        new_identifier: 'ABC-NCD-23',
        category: 'mapped_prefix'
      )
    )
  end

  it 'uses a reviewed facility mapping when the prefix is entirely missing' do
    task = build_task
    active = active_row(
      id: 1,
      patient_id: 10,
      identifier: '-NCD-23',
      facility_name: 'Mapped Clinic'
    )

    plan = cleanup_plan(
      task,
      active_rows: [active],
      reservations: [reservation(active)],
      mapping: { 'Mapped Clinic' => { 'ncd_prefix' => 'ABC' } }
    )

    expect(plan[:changes]).to contain_exactly(
      hash_including(
        patient_identifier_id: 1,
        new_identifier: 'ABC-NCD-23',
        category: 'missing_prefix'
      )
    )
  end

  it 'warns without changing a standard identifier whose prefix differs from its current facility mapping' do
    task = build_task
    active = active_row(
      id: 1,
      patient_id: 10,
      identifier: 'WRONG-NCD-23',
      facility_name: 'Mapped Clinic'
    )

    plan = cleanup_plan(
      task,
      active_rows: [active],
      reservations: [reservation(active)],
      mapping: { 'Mapped Clinic' => { 'ncd_prefix' => 'ABC' } }
    )

    expect(plan[:changes]).to be_empty
    expect(plan[:unresolved]).to be_empty
    expect(plan[:warnings]).to contain_exactly(
      hash_including(
        patient_identifier_id: 1,
        reason: 'prefix differs from the current mapped facility',
        suggestion: 'ABC-NCD-23'
      )
    )
  end

  it 'supports review-only collision handling' do
    task = build_task(collision_mode: 'review')
    active = active_row(id: 2, patient_id: 20, identifier: 'abc-NCD-1')
    existing = active_row(id: 1, patient_id: 10, identifier: 'ABC-NCD-1')

    plan = cleanup_plan(
      task,
      active_rows: [active],
      reservations: [reservation(existing), reservation(active)]
    )

    expect(plan[:changes]).to be_empty
    expect(plan[:unresolved]).to contain_exactly(
      hash_including(
        patient_identifier_id: 2,
        reason: 'target identifier is already reserved',
        suggestion: 'ABC-NCD-2'
      )
    )
  end

  it 'rejects the unsafe legacy keep collision mode' do
    expect { build_task(collision_mode: 'keep') }
      .to raise_error(ArgumentError, /COLLISION_MODE must be one of/)
  end

  it 'updates only the active row whose original identifier still matches the plan' do
    task = build_task
    connection = instance_double(ActiveRecord::ConnectionAdapters::Mysql2Adapter)
    change = {
      patient_identifier_id: 12,
      old_identifier: 'abc-NCD-1',
      new_identifier: 'ABC-NCD-1'
    }

    allow(task).to receive(:connection).and_return(connection)
    allow(connection).to receive(:transaction).and_yield
    expect(task).to receive(:update_sanitized) do |sql, *binds|
      expect(sql).to include('identifier_type = ?', 'voided = 0', 'identifier = ?')
      expect(binds).to eq(['ABC-NCD-1', 12, 31, 'abc-NCD-1'])
      1
    end

    expect { task.send(:apply_changes, [change]) }.not_to raise_error
  end

  it 'aborts the transaction if a row changed after the cleanup plan was built' do
    task = build_task
    connection = instance_double(ActiveRecord::ConnectionAdapters::Mysql2Adapter)
    change = {
      patient_identifier_id: 12,
      old_identifier: 'abc-NCD-1',
      new_identifier: 'ABC-NCD-1'
    }

    allow(task).to receive(:connection).and_return(connection)
    allow(connection).to receive(:transaction).and_yield
    allow(task).to receive(:update_sanitized).and_return(0)

    expect { task.send(:apply_changes, [change]) }
      .to raise_error(RuntimeError, /changed after the cleanup plan was built/)
  end

  it 'changes another Karonga prefix to KDH while preserving an available number' do
    task = build_task
    active = facility_row(id: 10, patient_id: 20, identifier: 'KA-NCD-614')

    plan = facility_cleanup_plan(
      task,
      rows: [active],
      reservations: [reservation(active)]
    )

    expect(plan[:changes]).to contain_exactly(
      hash_including(
        action: 'update',
        patient_identifier_id: 10,
        patient_id: 20,
        old_identifier: 'KA-NCD-614',
        new_identifier: 'KDH-NCD-614',
        category: 'facility_prefix'
      )
    )
  end

  it 'allocates the next unused KDH number when the desired KDH number is reserved' do
    task = build_task
    active = facility_row(id: 10, patient_id: 20, identifier: 'KA-NCD-614')
    existing = active_row(id: 11, patient_id: 30, identifier: 'KDH-NCD-614')

    plan = facility_cleanup_plan(
      task,
      rows: [active],
      reservations: [reservation(active), reservation(existing)]
    )

    expect(plan[:changes]).to contain_exactly(
      hash_including(
        action: 'update',
        new_identifier: 'KDH-NCD-1',
        category: 'facility_prefix_collision_next_number',
        collision_original_identifier: 'KDH-NCD-614'
      )
    )
  end

  it 'plans an insert with the next unused KDH number for an enrolled patient without one' do
    task = build_task
    missing = facility_row(id: nil, patient_id: 20, identifier: nil)
    existing = active_row(id: 11, patient_id: 30, identifier: 'KDH-NCD-1')

    plan = facility_cleanup_plan(
      task,
      rows: [missing],
      reservations: [reservation(existing)]
    )

    expect(plan[:changes]).to contain_exactly(
      hash_including(
        action: 'insert',
        patient_identifier_id: nil,
        patient_id: 20,
        new_identifier: 'KDH-NCD-2',
        identifier_location_id: 568,
        creator: 2,
        category: 'missing_identifier_next_number'
      )
    )
  end

  it 'uses a guarded insert for a missing facility NCD identifier' do
    task = build_task
    change = {
      action: 'insert',
      patient_id: 20,
      new_identifier: 'KDH-NCD-2',
      identifier_location_id: 568,
      creator: 2
    }

    expect(task).to receive(:update_sanitized) do |sql, *binds|
      expect(sql).to include('INSERT INTO', 'patient_program', 'NOT EXISTS')
      expect(binds[0, 5]).to eq([20, 'KDH-NCD-2', 31, 568, 2])
      expect(binds).to include(20, 568, 31, 'KDH-NCD-2')
      1
    end

    expect { task.send(:apply_insert_change, change) }.not_to raise_error
  end
end
