# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Stage, type: :model do
  it 'allows the HTS queue stage' do
    stage = described_class.new(stage: 'HTS')

    stage.validate

    expect(described_class::VALID_STAGES).to include('HTS')
    expect(stage.errors[:stage]).to be_empty
  end

  it 'allows the AETC test results queue stage' do
    stage = described_class.new(stage: 'TEST_RESULTS')

    stage.validate

    expect(described_class::VALID_STAGES).to include('TEST_RESULTS')
    expect(stage.errors[:stage]).to be_empty
  end

  it 'retains a triage result when later stage metadata does not repeat it' do
    stage = described_class.new
    service = StagesService.new

    service.send(:assign_stage_metadata, stage, triage_result: 'red')
    service.send(:assign_stage_metadata, stage, department: 'Medical')

    expect(stage.triage_result).to eq('red')
    expect(stage.department).to eq('Medical')
  end
end
