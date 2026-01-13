# frozen_string_literal: true

class LabTestService
  class << self
    ENGINES = {
      'HIV PROGRAM' => ArtService::LabTestsEngine,
      'TB PROGRAM' => TbService::LabTestsEngine
    }.freeze

    def load_engine(program_id)
      program = Program.find program_id
      engine = ENGINES[program.name.upcase]
      engine.new program:
    end

    def all_test_result_indicators()
      # Verify that the specified test_type is indeed a test_type
      test = ConceptSet.find_members_by_name(Lab::Metadata::TEST_TYPE_CONCEPT_NAME)
                       .select(:concept_id)

      # From the members above, filter out only those concepts that are result indicators
      measures = ConceptSet.find_members_by_name(Lab::Metadata::TEST_RESULT_INDICATOR_CONCEPT_NAME)
                           .select(:concept_id)

      ConceptSet.where(concept_set: measures, concept_id: test)
                .joins('INNER JOIN concept_name AS measure ON measure.concept_id = concept_set.concept_set')
                .group('measure.concept_id')
                .map { |concept| {name:ConceptName.where(concept_id: concept.concept_set).pluck(:name).first, concept_id: concept.concept_id, concept_set:concept.concept_set }  }
    end
  end
end
