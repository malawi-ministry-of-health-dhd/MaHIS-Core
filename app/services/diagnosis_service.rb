# frozen_string_literal: true

class DiagnosisService
  DEFAULT_CONCEPT_SET_NAME = 'ICD-10 Volume 3 Diagnosis'

  def find_diagnosis(query, concept_set_id: nil, concept_set_name: nil)
    if concept_set_id.present? || concept_set_name.present?
      concept_set_id = resolve_concept_set_id(concept_set_id, concept_set_name)
      return ConceptName.none unless concept_set_id

      return find_concept_set_diagnosis(query, concept_set_id)
    end

    find_icd11_diagnosis(query)
  end

  private

  def resolve_concept_set_id(concept_set_id, concept_set_name)
    return Concept.find_by_name(concept_set_name)&.concept_id if concept_set_name.present?
    return concept_set_id if ConceptSet.where(concept_set: concept_set_id).exists?

    Concept.find_by_name(DEFAULT_CONCEPT_SET_NAME)&.concept_id
  end

  def find_concept_set_diagnosis(query, concept_set_id)
    q = query.to_s.strip

    scope = ConceptName
            .joins('INNER JOIN concept_set s ON s.concept_id = concept_name.concept_id')
            .where('s.concept_set = ?', concept_set_id)
            .where(locale_preferred: 1, voided: 0)

    if q.present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
      scope = scope.where('concept_name.name LIKE ?', term)
    end

    results = scope
      .select(
        'concept_name.concept_id',
        'concept_name.name AS name'
      )
      .distinct

    q.present? ? results.order(Arel.sql(ranked_name_order(q))) : results.order('concept_name.name')
  end

  def find_icd11_diagnosis(query)
    q = query.to_s.strip
    return ConceptName.none if q.blank?

    # Match the term anywhere in the name/code (start, middle or end), and
    # escape LIKE wildcards so a literal % or _ in the query is searched as-is.
    term = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"

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
                  'concept_map.concept_code AS code'
                )
                .distinct

    diagnoses.where(
      'concept_name.name LIKE :term OR concept_map.concept_code LIKE :term',
      term: term
    ).order(Arel.sql(ranked_name_or_code_order(q)))
  end

  def ranked_name_order(query)
    escaped_query = ActiveRecord::Base.sanitize_sql_like(query)

    ActiveRecord::Base.sanitize_sql_array(
      [
        'CASE WHEN concept_name.name LIKE ? THEN 0 WHEN concept_name.name LIKE ? THEN 1 ELSE 2 END, CHAR_LENGTH(concept_name.name), concept_name.name',
        "#{escaped_query}%",
        "% #{escaped_query}%"
      ]
    )
  end

  def ranked_name_or_code_order(query)
    escaped_query = ActiveRecord::Base.sanitize_sql_like(query)

    ActiveRecord::Base.sanitize_sql_array(
      [
        'CASE WHEN concept_name.name LIKE ? THEN 0 WHEN concept_name.name LIKE ? THEN 1 WHEN concept_map.concept_code LIKE ? THEN 2 ELSE 3 END, CHAR_LENGTH(concept_name.name), concept_name.name',
        "#{escaped_query}%",
        "% #{escaped_query}%",
        "#{escaped_query}%"
      ]
    )
  end
end
