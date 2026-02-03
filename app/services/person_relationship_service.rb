# frozen_string_literal: true

class PersonRelationshipService
  def initialize(person)
    @person = person
  end

  def get_relationship(relationship_id)
    relationship = Relationship.find_by relationship_id:,
                                        person_a: @person.person_id
    raise NotFoundError, 'Relationship not found' unless relationship

    relationship
  end

  def void_relationship(relationship_id, reason)
    get_relationship(relationship_id).void(reason)
  end

  def find_relationships(filters)
    relationships = Relationship.where 'person_a = :person', person: @person.person_id
    relationships = relationships.where filters unless filters.empty?
    relationships
  end

  def find_guardians
    Relationship.joins(:type).where 'person_a = ? AND b_is_to_a = ?',
                                    @person.person_id,
                                    'Guardian'
  end

  def create_relationship(person, relationship_type)
    Relationship.create person: @person,
                        relation: person,
                        type: relationship_type
  end

  def find_relationships_with_details(filters = {})
  # Convert filters to hash if it's ActionController::Parameters
  filters = filters.to_h if filters.respond_to?(:to_h)
  
  relationships = Relationship
    .joins(:type)
    .joins('INNER JOIN person pa ON relationship.person_a = pa.person_id')
    .joins('INNER JOIN person pb ON relationship.person_b = pb.person_id')
    # Remove the preferred = 1 condition, just check voided
    .joins('LEFT JOIN person_name pna ON pa.person_id = pna.person_id AND pna.voided = 0')
    .joins('LEFT JOIN person_name pnb ON pb.person_id = pnb.person_id AND pnb.voided = 0')
    .joins('LEFT JOIN patient_identifier pia ON pa.person_id = pia.patient_id AND pia.voided = 0')
    .joins('LEFT JOIN patient_identifier pib ON pb.person_id = pib.patient_id AND pib.voided = 0')
    .select(
      'relationship.*',
      'relationship_type.a_is_to_b',
      'relationship_type.b_is_to_a',
      'relationship_type.description as relationship_description',
      'pna.given_name as person_a_given_name',
      'pna.family_name as person_a_family_name',
      'pa.gender as person_a_gender',
      'pa.birthdate as person_a_birthdate',
      'pnb.given_name as person_b_given_name',
      'pnb.family_name as person_b_family_name',
      'pb.gender as person_b_gender',
      'pb.birthdate as person_b_birthdate',
      'pia.identifier as person_a_identifier',
      'pib.identifier as person_b_identifier'
    )
    .where(person_a: @person.person_id)
    .where(voided: 0)
  
  # Apply filters
  relationships = relationships.where(person_b: filters[:person_b]) if filters[:person_b].present?
  relationships = relationships.where(relationship: filters[:relationship]) if filters[:relationship].present?
  
  relationships.order(date_created: :desc)
end
end