# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtService::LabTestsEngine do
  subject { ArtService::LabTestsEngine.new(program:) }
  let(:program) { Program.find_by_name('HIV PROGRAM') || create(:program, name: 'HIV PROGRAM') }

  def make_test_type(concept)
    set = ConceptName.find_by_name('Test type')&.concept_id || create(:concept).tap { |c| create(:concept_name, concept: c, name: 'Test type') }.concept_id

    create :concept_set, concept_set: set, concept:
  end

  def make_sample_type(concept, test_type)
    samples_set = ConceptName.find_by_name('Specimen Type')&.concept_id || create(:concept).tap { |c| create(:concept_name, concept: c, name: 'Specimen Type') }.concept_id

    create(:concept_set, concept_set: samples_set, concept:)
    create :concept_set, concept_set: test_type.concept_id, concept:
  end

  before(:each) do
    setup_cohort_test_data
    @mock_nlims = instance_double(Nlims)
    allow(Nlims).to receive(:instance).and_return(@mock_nlims)
  end

  after(:each) do
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS=0')
    ConceptSet.unscoped.delete_all
    Observation.unscoped.delete_all
    Encounter.unscoped.delete_all
    ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS=1')
  end

  describe :type do
    let(:test_type_concept) { create :concept_with_name }
    let(:test_type) { make_test_type(test_type_concept) }

    it 'retrieves a test type by concept id' do
      concept = subject.type(test_type.concept.concept_id)

      expect(concept.concept_id).to eq(test_type.concept.concept_id)
    end

    it "doesn't retrieve concepts not under Lab test type concept set" do
      concept = create :concept

      expect { subject.type(concept.concept_id) }.to raise_error NotFoundError
    end
  end

  describe :types do
    let(:test_type_concept) { create :concept_with_name }
    let(:test_type) { make_test_type(test_type_concept) }

    it 'retrieves test types by partial name' do
      concept_name = test_type.concept.concept_names.first.name
      search_string_size = (concept_name.size / 2).to_i
      allow(@mock_nlims).to receive(:test_types).and_return([concept_name, 'Other test'])
      test_types = subject.types(search_string: concept_name[0..search_string_size])
      match = test_types.find { |test_type| test_type == concept_name }

      expect(match).not_to be_nil
    end
  end

  describe :panels do
    let(:sample_type_concept) { create :concept_with_name }
    let(:test_type) { make_test_type(create(:concept_with_name)) }
    let(:sample_type) { make_sample_type(sample_type_concept, test_type.concept) }

    it 'retrieves sample types by test type' do
      test_type_name = sample_type.set.concept_names.first.name
      allow(@mock_nlims).to receive(:specimen_types).with(test_type_name).and_return([OpenStruct.new(concept_id: sample_type.concept_id)])
      retrieved_sample_types = subject.panels(test_type_name)

      expect(retrieved_sample_types.size).to eq(1)
      expect(retrieved_sample_types.first.concept_id).to eq(sample_type.concept_id)
    end
  end
end
