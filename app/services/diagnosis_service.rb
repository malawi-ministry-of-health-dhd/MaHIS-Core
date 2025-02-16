# frozen_string_literal: true

class DiagnosisService
  def find_diagnosis(filters)
    filters = filters.dup # May be modified

    id = filters.delete(:id)
    name = filters.delete(:name)
    count = filters.delete(:count)
    query = ConceptName.where("s.concept_set = ?
      AND concept_name.name LIKE (?)", id,
                              "%#{name}%").joins("INNER JOIN concept_set s ON
      s.concept_id = concept_name.concept_id")

    if count
      query.select('DISTINCT concept_name.concept_id').count
    else
      query.group('concept_name.concept_id')
    end
  end
end
