class ConceptName < VoidableRecord
  self.table_name = :concept_name
  self.primary_key = :concept_name_id

  belongs_to :concept

  has_many :concept_maps,
           foreign_key: :concept_id,
           primary_key: :concept_id

  has_many :concept_sources,
           through: :concept_maps

  scope :preferred, -> { where(locale_preferred: 1, voided: 0) }
end
