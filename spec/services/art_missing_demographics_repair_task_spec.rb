# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtMissingDemographicsRepairTask do
  it 'requires explicit approval and confirmation before applying changes' do
    expect do
      described_class.new('APPLY' => '1', 'USER_ID' => '1')
    end.to raise_error(/APPROVE_ALL=1/)

    expect do
      described_class.new('APPLY' => '1', 'APPROVE_ALL' => '1', 'USER_ID' => '1')
    end.to raise_error(/CONFIRM=RESTORE_MISSING_ART_DEMOGRAPHICS_FROM_SOURCE/)
  end

  it 'matches source demographics using both person UUID and active ARV number' do
    connection = double('connection')
    allow(connection).to receive(:quote_table_name) { |value| "`#{value}`" }
    task = described_class.new({}, connection: connection)
    captured_sql = nil
    allow(task).to receive(:select_all) do |sql|
      captured_sql = sql
      []
    end

    task.send(:candidates)

    expect(captured_sql).to include('source.uuid=target.uuid')
    expect(captured_sql).to include('source_arv.identifier=target_arv.identifier')
    expect(captured_sql).to include('target_program.program_id=1')
    expect(captured_sql).to include("UPPER(TRIM(COALESCE(target.gender, ''))) NOT IN ('M', 'MALE', 'F', 'FEMALE')")
    expect(captured_sql).to include("UPPER(TRIM(source.gender)) IN ('M', 'MALE', 'F', 'FEMALE')")
    expect(captured_sql).to include('OR (target.birthdate IS NULL AND source.birthdate IS NOT NULL)')
  end

  it 'restores a report-invalid gender from the matched source patient' do
    connection = double('connection')
    allow(connection).to receive(:quote_table_name) { |value| "`#{value}`" }
    allow(connection).to receive(:quote_column_name) { |value| "`#{value}`" }
    allow(connection).to receive(:quote) { |value| "'#{value}'" }
    task = described_class.new({}, connection: connection)
    task.instance_variable_set(:@operator_user_id, 1)
    allow(task).to receive(:select_all).and_return([{
      'person_id' => 275_800,
      'uuid' => 'patient-uuid',
      'gender' => 'Undetermined',
      'birthdate' => Date.new(1974, 7, 1),
      'birthdate_estimated' => 0
    }])
    update_sql = nil
    allow(connection).to receive(:update) do |sql|
      update_sql = sql
      1
    end

    task.send(:repair!, {
      'target_id' => 275_800,
      'uuid' => 'patient-uuid',
      'source_gender' => 'F',
      'source_birthdate' => Date.new(1974, 7, 1),
      'source_birthdate_estimated' => 0
    })

    expect(update_sql).to include("`gender`='F'")
    expect(update_sql).to include('gender <=>', 'birthdate <=>', 'birthdate_estimated <=>')
  end

  it 'restores birthdate without requiring a valid source gender' do
    connection = double('connection')
    allow(connection).to receive(:quote_table_name) { |value| "`#{value}`" }
    allow(connection).to receive(:quote_column_name) { |value| "`#{value}`" }
    allow(connection).to receive(:quote) { |value| value.nil? ? 'NULL' : "'#{value}'" }
    task = described_class.new({}, connection: connection)
    task.instance_variable_set(:@operator_user_id, 1)
    allow(task).to receive(:select_all).and_return([{
      'person_id' => 123,
      'uuid' => 'patient-uuid',
      'gender' => 'F',
      'birthdate' => nil,
      'birthdate_estimated' => nil
    }])
    update_sql = nil
    allow(connection).to receive(:update) do |sql|
      update_sql = sql
      1
    end

    task.send(:repair!, {
      'target_id' => 123,
      'uuid' => 'patient-uuid',
      'source_gender' => 'Undetermined',
      'source_birthdate' => Date.new(1980, 1, 1),
      'source_birthdate_estimated' => 1
    })

    expect(update_sql).not_to include('SET `gender`')
    expect(update_sql).to include("`birthdate`='1980-01-01'", "`birthdate_estimated`='1'")
  end
end
