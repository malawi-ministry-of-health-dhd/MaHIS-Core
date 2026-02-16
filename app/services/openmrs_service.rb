# frozen_string_literal: true

# Openmrs Service
class OpenmrsService
  include ModelUtils

  def self.find_concept(uuid)
    Concept.joins(:concept_name).where(Concept.arel_table[:uuid].eq(uuid)
          .or(ConceptName.arel_table[:uuid].eq(uuid)))&.first
  end
end
