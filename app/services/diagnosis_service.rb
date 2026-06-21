# frozen_string_literal: true

class DiagnosisService
  def find_diagnosis(query)
    q = query.to_s.strip

    ConceptName
      .joins(concept_maps: :concept_source)
      .where(
        locale_preferred: 1,
        voided: 0
      )
      .where('LOWER(concept_source.name) = ?', 'icd-11')
      .where(
        'LOWER(concept_name.name) LIKE :q OR LOWER(concept_map.concept_code) LIKE :q',
        q: "#{q.downcase}%"
      )
      .select(
        'concept_name.concept_id',
        'concept_name.name AS name',
        'concept_source.name AS code_system',
        'concept_map.concept_code AS code',
      )
      .distinct
      .order('LOWER(concept_name.name), concept_name.name')
  end
end
