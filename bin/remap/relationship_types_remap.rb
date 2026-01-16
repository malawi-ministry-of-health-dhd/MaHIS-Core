def mahis_relationship_type_from_source(source_relationship_type_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT relationship_type_id, a_is_to_b, b_is_to_a 
    FROM relationship_type
    WHERE relationship_type_id = #{source_relationship_type_id}
  SQL
end

def relationship_type_has_changed?(relationship_type)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM relationship_type 
      WHERE relationship_type_id = #{relationship_type.relationship_type_id} 
    AND a_is_to_b = #{quote(relationship_type.a_is_to_b)}
    AND b_is_to_a = #{quote(relationship_type.b_is_to_a)}
  SQL
  !val.present?
end

def load_relationship_types_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_relationship_types.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def relationship_type_moved_to(relationship_type)
  # find relationship_type with the old names else create one
  relationship_type_in_mahis = RelationshipType.find_by(a_is_to_b: relationship_type.a_is_to_b&.strip, b_is_to_a: relationship_type.b_is_to_a&.strip)
  if relationship_type_in_mahis.present?
    return OpenStruct.new(relationship_type_id: relationship_type_in_mahis.relationship_type_id, a_is_to_b: relationship_type_in_mahis.a_is_to_b, b_is_to_a: relationship_type_in_mahis.b_is_to_a)
  end

  # create a new relationship_type
  new_relationship_type = RelationshipType.create(
    a_is_to_b: relationship_type.a_is_to_b,
    b_is_to_a: relationship_type.b_is_to_a,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_relationship_type.reload

  OpenStruct.new(relationship_type_id: new_relationship_type.relationship_type_id, a_is_to_b: relationship_type.a_is_to_b, b_is_to_a: relationship_type.b_is_to_a)
end


def remap_relationship_types
  ActiveRecord::Base.transaction do
    load_relationship_types_file.each do |relationship_type|
      if relationship_type_has_changed?(relationship_type)
        moved_relationship_type = relationship_type_moved_to(relationship_type)
        
        log "RelationshipType #{relationship_type.relationship_type_id} (#{relationship_type.a_is_to_b}/#{relationship_type.b_is_to_a}) has changed to #{moved_relationship_type.relationship_type_id} (#{moved_relationship_type.a_is_to_b}/#{moved_relationship_type.b_is_to_a})"
        
        update_references(relationship_type, moved_relationship_type, 'relationship_types')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
