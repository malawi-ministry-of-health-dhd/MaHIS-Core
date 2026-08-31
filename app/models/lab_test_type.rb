# frozen_string_literal: true

# Lab test types are modelled as OpenMRS concepts that belong to the
# "Test type" concept set. This thin model exposes them via the concept
# table while guaranteeing the concept is actually a lab test type.
class LabTestType < Concept
  TEST_TYPE_CONCEPT = 'Test type'

  def self.find(type_id)
    concept = Concept.find_by(concept_id: type_id)
    raise NotFoundError, "Lab test type #{type_id} not found" unless concept
    raise NotFoundError, "Concept #{type_id} is not a lab test type" unless lab_test_type?(concept)

    concept
  end

  def self.lab_test_type?(concept)
    test_type_set = ConceptName.find_by_name(TEST_TYPE_CONCEPT)&.concept_id
    return false unless test_type_set

    ConceptSet.where(concept_set: test_type_set, concept: concept.concept_id).exists?
  end
end
