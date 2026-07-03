# frozen_string_literal: true

class DiagnosisService
  def find_diagnosis(query, concept_set_id: nil)
    return find_concept_set_diagnosis(query, concept_set_id) if concept_set_id.present?

    find_icd11_diagnosis(query)
  end

  private

  def find_concept_set_diagnosis(query, concept_set_id)
    q = query.to_s.strip
    term = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"

    scope = ConceptName
            .joins('INNER JOIN concept_set s ON s.concept_id = concept_name.concept_id')
            .where('s.concept_set = ?', concept_set_id)
            .where(locale_preferred: 1, voided: 0)

    scope = scope.where('concept_name.name LIKE ?', term) if q.present?

    scope
      .select(
        'concept_name.concept_id',
        'concept_name.name AS name'
      )
      .distinct
      .order('concept_name.name')
  end

  def find_icd11_diagnosis(query)
    q = query.to_s.strip
    return ConceptName.none if q.blank?

    # Match the term anywhere in the name/code (start, middle or end), and
    # escape LIKE wildcards so a literal % or _ in the query is searched as-is.
    term = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"

    ConceptName
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
