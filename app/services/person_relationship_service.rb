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
    relationships = Relationship.for_person(@person.person_id)
    relationships = relationships.where(filters) unless filters.empty?
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
    
    person_id = filters[:person_id] || @person.person_id
    
    # Relationships where current person is person_a
    relationships_as_a = Relationship
      .joins(:type)
      .joins('INNER JOIN person pb ON relationship.person_b = pb.person_id')
      .joins('LEFT JOIN person_name pnb ON pb.person_id = pnb.person_id AND pnb.voided = 0')
      .joins('LEFT JOIN patient_identifier pib ON pb.person_id = pib.patient_id AND pib.voided = 0')
      .select(
        'relationship.relationship_id',
        'relationship_type.b_is_to_a as relationship_type',
        'pnb.given_name as related_person_given_name',
        'pnb.family_name as related_person_family_name',
        'pb.gender as related_person_gender',
        'pb.birthdate as related_person_birthdate',
        'pib.identifier as related_person_identifier'
      )
      .where(person_a: person_id)
      .where('relationship.voided = 0')
    
    # Relationships where current person is person_b (reverse direction)
    relationships_as_b = Relationship
      .joins(:type)
      .joins('INNER JOIN person pa ON relationship.person_a = pa.person_id')
      .joins('LEFT JOIN person_name pna ON pa.person_id = pna.person_id AND pna.voided = 0')
      .joins('LEFT JOIN patient_identifier pia ON pa.person_id = pia.patient_id AND pia.voided = 0')
      .select(
        'relationship.relationship_id',
        'relationship_type.a_is_to_b as relationship_type',
        'pna.given_name as related_person_given_name',
        'pna.family_name as related_person_family_name',
        'pa.gender as related_person_gender',
        'pa.birthdate as related_person_birthdate',
        'pia.identifier as related_person_identifier'
      )
      .where(person_b: person_id)
      .where('relationship.voided = 0')
    
    # Apply additional filters if provided
    if filters[:person_b].present?
      relationships_as_a = relationships_as_a.where(person_b: filters[:person_b])
      relationships_as_b = relationships_as_b.where(person_a: filters[:person_b])
    end
    
    if filters[:relationship].present?
      relationships_as_a = relationships_as_a.where(relationship: filters[:relationship])
      relationships_as_b = relationships_as_b.where(relationship: filters[:relationship])
    end
    
    # Combine results and convert to array of hashes
    combined_results = []
    
    relationships_as_a.each do |rel|
      combined_results << {
        'relationship_id' => rel.relationship_id,
        'relationship_type' => rel.relationship_type,
        'related_person_given_name' => rel.related_person_given_name,
        'related_person_family_name' => rel.related_person_family_name,
        'related_person_gender' => rel.related_person_gender,
        'related_person_birthdate' => rel.related_person_birthdate,
        'related_person_identifier' => rel.related_person_identifier
      }
    end
    
    relationships_as_b.each do |rel|
      combined_results << {
        'relationship_id' => rel.relationship_id,
        'relationship_type' => rel.relationship_type,
        'related_person_given_name' => rel.related_person_given_name,
        'related_person_family_name' => rel.related_person_family_name,
        'related_person_gender' => rel.related_person_gender,
        'related_person_birthdate' => rel.related_person_birthdate,
        'related_person_identifier' => rel.related_person_identifier
      }
    end
    
    # Sort by relationship_id descending
    combined_results.sort_by { |r| -r['relationship_id'] }
  end
end