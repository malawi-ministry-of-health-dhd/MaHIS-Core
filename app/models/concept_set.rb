# frozen_string_literal: true

class ConceptSet < ApplicationRecord
  self.table_name = :concept_set
  self.primary_key = :concept_set_id

  belongs_to :set, foreign_key: :concept_set, class_name: 'Concept'
  belongs_to :concept

  ##
  # Find all members of the concept set under name +concept_set_name+.
  #
  # Returns: An ActiveRecord::Relation of ConceptSets
  def self.find_members_by_name(concept_set_name)
    concept = ConceptName.where('LOWER(name) = ?', concept_set_name.to_s.downcase)
                         .select(:concept_id)
    ConceptSet.where(set: concept)
  end

  scope :filter_members, lambda { |name: nil|
                           where(
                             concept: ConceptName
                               .where('LOWER(name) LIKE ?', "#{name.to_s.downcase}%")
                               .select(:concept_id)
                           )
                         }
end
