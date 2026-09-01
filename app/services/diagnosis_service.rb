# frozen_string_literal: true

class DiagnosisService
  DEFAULT_CONCEPT_SET_NAME = 'ICD-10 Volume 3 Diagnosis'

  # The OPD workflow records the primary diagnosis as a "Main Diagnosis" (157897)
  # observation, value_coded = the ICD-10 concept, on a "Diagnosis" (38) encounter.
  MAIN_DIAGNOSIS_CONCEPT_ID = 157_897
  DIAGNOSIS_ENCOUNTER_TYPE_ID = 38
  DEFAULT_RECENCY_DAYS = 90
  MAX_COMMON_DIAGNOSES = 50

  def find_diagnosis(query, concept_set_id: nil, concept_set_name: nil)
    if concept_set_id.present? || concept_set_name.present?
      concept_set_id = resolve_concept_set_id(concept_set_id, concept_set_name)
      return ConceptName.none unless concept_set_id

      return find_concept_set_diagnosis(query, concept_set_id)
    end

    find_icd11_diagnosis(query)
  end

  # Recent, most-frequently recorded OPD diagnoses for a site, used to populate the
  # "Common diagnoses" quick-pick. Counts Main Diagnosis observations within a recency
  # window, scoped to the given (or current user's) location, ordered by frequency then
  # recency. Returns [{ concept_id:, name:, count:, last_seen: }] capped at `limit`.
  def recent_common_diagnoses(limit: 15, since: nil, location_id: nil)
    limit = limit.to_i
    limit = 15 if limit <= 0
    limit = MAX_COMMON_DIAGNOSES if limit > MAX_COMMON_DIAGNOSES

    since_date = (since.present? ? since.to_date : Date.today - DEFAULT_RECENCY_DAYS)
                 .strftime('%Y-%m-%d 00:00:00')
    loc = location_id.presence || User.current&.location_id

    scope = Observation
            .where(concept_id: MAIN_DIAGNOSIS_CONCEPT_ID, voided: 0)
            .where.not(value_coded: nil)
            .joins('INNER JOIN encounter e ON e.encounter_id = obs.encounter_id AND e.voided = 0')
            .where('e.encounter_type = ?', DIAGNOSIS_ENCOUNTER_TYPE_ID)
            .where('obs.obs_datetime >= ?', since_date)
    scope = scope.where('e.location_id = ?', loc) if loc.present?

    rows = scope
           .group('obs.value_coded')
           .order(Arel.sql('COUNT(*) DESC, MAX(obs.obs_datetime) DESC'))
           .limit(limit)
           .pluck(Arel.sql('obs.value_coded'), Arel.sql('COUNT(*)'), Arel.sql('MAX(obs.obs_datetime)'))

    names = diagnosis_names(rows.map(&:first))

    rows.map do |value_coded, freq, last_seen|
      { concept_id: value_coded, name: names[value_coded], count: freq.to_i, last_seen: last_seen }
    end
  end

  private

  # Resolve concept names, preferring the locale-preferred name and falling back to any
  # non-voided name so a diagnosis is never left without a label.
  def diagnosis_names(concept_ids)
    return {} if concept_ids.blank?

    names = ConceptName.where(concept_id: concept_ids, voided: 0, locale_preferred: 1)
                       .pluck(:concept_id, :name).to_h
    missing = concept_ids - names.keys
    if missing.any?
      ConceptName.where(concept_id: missing, voided: 0)
                 .pluck(:concept_id, :name)
                 .each { |cid, nm| names[cid] ||= nm }
    end
    names
  end


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

    # Also match the concept's other names, so a clinical synonym seeded against
    # an existing ICD-11 concept is findable ("Community Acquired Pneumonia" ->
    # CA40.Z "Pneumonia, organism unspecified"). The row itself stays anchored on
    # the locale-preferred name above, so the list still displays and stores the
    # official ICD-11 title rather than the synonym.
    diagnoses.where(
      'concept_name.name LIKE :term OR concept_map.concept_code LIKE :term
       OR EXISTS (
            SELECT 1 FROM concept_name synonym
            WHERE synonym.concept_id = concept_name.concept_id
              AND synonym.voided = 0
              AND synonym.name LIKE :term
          )',
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
