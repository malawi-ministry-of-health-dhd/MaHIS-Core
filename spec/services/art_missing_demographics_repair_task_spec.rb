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
    expect(captured_sql).to include("NULLIF(TRIM(target.gender), '') IS NULL OR target.birthdate IS NULL")
  end
end
