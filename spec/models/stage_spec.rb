# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Stage, type: :model do
  it 'allows the HTS queue stage' do
    stage = described_class.new(stage: 'HTS')

    stage.validate

    expect(described_class::VALID_STAGES).to include('HTS')
    expect(stage.errors[:stage]).to be_empty
  end
end
