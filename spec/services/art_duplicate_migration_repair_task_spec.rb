# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtDuplicateMigrationRepairTask do
  it 'requires one explicit confirmation before applying both repairs' do
    expect do
      described_class.new('APPLY' => '1', 'APPROVE_ALL' => '1', 'USER_ID' => '1')
    end.to raise_error(/CONFIRM=RESTORE_ART_DUPLICATE_MIGRATION_DATA/)
  end

  it 'runs rollback before demographic repair and supplies each task confirmation' do
    events = []
    child_environments = []
    rollback = double('rollback', run: nil)
    demographics = double('demographics', run: nil)
    allow(rollback).to receive(:run) { events << :rollback }
    allow(demographics).to receive(:run) { events << :demographics }
    rollback_class = double('rollback class')
    demographics_class = double('demographics class')
    allow(rollback_class).to receive(:new) do |env|
      child_environments << env
      rollback
    end
    allow(demographics_class).to receive(:new) do |env|
      child_environments << env
      demographics
    end

    described_class.new(
      {
        'APPLY' => '1', 'APPROVE_ALL' => '1', 'USER_ID' => '1',
        'CONFIRM' => described_class::CONFIRMATION,
        'SOURCE_DB' => 'source_copy', 'TARGET_DB' => 'target_copy'
      },
      rollback_task_class: rollback_class,
      demographics_task_class: demographics_class
    ).run

    expect(events).to eq(%i[rollback demographics])
    expect(child_environments.map { |env| env['CONFIRM'] }).to eq([
      ArtDuplicateMergeRollbackTask::CONFIRMATION,
      ArtMissingDemographicsRepairTask::CONFIRMATION
    ])
    expect(child_environments).to all(include('SOURCE_DB' => 'source_copy', 'TARGET_DB' => 'target_copy'))
  end
end
