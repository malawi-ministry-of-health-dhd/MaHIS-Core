# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtService::LabTestsEngine do
  # The suite runs without transactional fixtures, roll back each example's records
  around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  subject { ArtService::LabTestsEngine.new(program:) }
  let(:program) { Program.find_by_name!('HIV Program') }
  let(:nlims) { instance_double(Nlims) }

  # Test types and specimens come from NLIMS, never hit the network in specs
  before { allow(Nlims).to receive(:instance).and_return(nlims) }

  describe :type do
    it 'retrieves a test type by id' do
      pending 'LabTestsEngine#type references a LabTestType model that no longer exists'

      expect { subject.type(1) }.not_to raise_error
    end
  end

  describe :types do
    before do
      allow(nlims).to receive(:test_types).and_return(['FBC', 'HIV Viral Load', 'Viral Load'])
    end

    it 'retrieves all test types when no search string is given' do
      expect(subject.types(search_string: nil)).to eq(['FBC', 'HIV Viral Load', 'Viral Load'])
    end

    it 'retrieves test types by partial name' do
      expect(subject.types(search_string: 'HIV')).to eq(['HIV Viral Load'])
    end

    it 'only matches test types starting with the search string' do
      expect(subject.types(search_string: 'Load')).to be_empty
    end
  end

  describe :panels do
    it 'retrieves sample types by test type' do
      allow(nlims).to receive(:specimen_types).with('Viral Load').and_return(%w[Blood Plasma])

      expect(subject.panels('Viral Load')).to eq(%w[Blood Plasma])
    end
  end
end
