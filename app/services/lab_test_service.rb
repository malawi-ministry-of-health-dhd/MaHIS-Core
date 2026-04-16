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

    def test_result_indicators(test_type_id)
      # Verify that the specified test_type is indeed a test_type
      test = ConceptSet.find_members_by_name(Lab::Metadata::TEST_TYPE_CONCEPT_NAME)
                       .where(concept_id: Concept.find_by(concept_id: test_type_id)&.id)
                       .select(:concept_id)

      # From the members above, filter out only those concepts that are result indicators
      measures = ConceptSet.find_members_by_name(Lab::Metadata::TEST_RESULT_INDICATOR_CONCEPT_NAME)
                           .select(:concept_id)

      sets = ConceptSet.where(concept_set: test, concept_id: measures)
      concept_ids = sets.pluck(:concept_id)
      return [] if concept_ids.empty?

      ActiveRecord::Base.connection.select_all <<~SQL
        SELECT ca.concept_id, ca.value_reference AS name, ca2.value_reference AS nlims_code, c.uuid
          FROM concept_attribute ca
          INNER JOIN concept_attribute ca2 ON ca.concept_id = ca2.concept_id
            AND ca2.attribute_type_id = #{ConceptAttributeType.nlims_code.concept_attribute_type_id}
          INNER JOIN concept c ON c.concept_id = ca.concept_id
          WHERE ca.attribute_type_id = #{ConceptAttributeType.test_catalogue_name.concept_attribute_type_id}
          AND ca.concept_id IN (#{concept_ids.push(0).join(',')})
          GROUP BY ca.concept_id
      SQL
    end

    def all_test_result_indicators
      test_type_ids = ConceptSet.find_members_by_name(Lab::Metadata::TEST_TYPE_CONCEPT_NAME).pluck(:concept_id)

      test_type_ids.flat_map do |test_type_id|
        test_result_indicators(test_type_id).map do |indicator|
          indicator.to_h.merge('concept_set' => test_type_id)
        end
      end
    end
  end
end
