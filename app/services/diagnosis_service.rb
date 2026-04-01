# frozen_string_literal: true

class DiagnosisService
  def find_diagnosis(query)
    q = query.to_s.strip

    ConceptName
      .joins(concept_maps: :concept_source)
      .where(
        concept_source: { name: 'ICD-11' },
        locale_preferred: 1,
        voided: 0
      )
      .where(
        'concept_name.name LIKE :q OR concept_map.concept_code LIKE :q',
        q: "#{q}%"
      )
      .select(
        'concept_name.concept_id',
        'concept_name.name AS name',
        'concept_source.name AS code_system',
        'concept_map.concept_code AS code',
      )
      .distinct
      .order('concept_name.name')
  end
end