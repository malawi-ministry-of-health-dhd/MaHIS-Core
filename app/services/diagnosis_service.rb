# frozen_string_literal: true

class DiagnosisService
  def find_diagnosis(query)
    q = query.to_s.strip
    diagnoses = ConceptName
      .joins(concept_maps: :concept_source)
      .where(
        concept_source: { name: 'ICD-11' },
        locale_preferred: 1,
        voided: 0
      )
      .select(
        'concept_name.concept_id',
        'concept_name.name AS name',
        'concept_source.name AS code_system',
        'concept_map.concept_code AS code',
      )
      .distinct
      .order('concept_name.name')

    return diagnoses if q.blank?

    # Match the term anywhere in the name/code (start, middle or end), and
    # escape LIKE wildcards so a literal % or _ in the query is searched as-is.
    term = "%#{q.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"

    diagnoses.where(
      'concept_name.name LIKE :term OR concept_map.concept_code LIKE :term',
      term: term
    )
  end
end
