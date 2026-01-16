def mahis_person_attribute_type_from_source(source_person_attribute_type_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT person_attribute_type_id, name 
    FROM person_attribute_type
    WHERE person_attribute_type_id = #{source_person_attribute_type_id}
  SQL
end

def person_attribute_type_has_changed?(person_attribute_type)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM person_attribute_type 
      WHERE person_attribute_type_id = #{person_attribute_type.person_attribute_type_id} 
    AND name = #{quote(person_attribute_type.name)}
  SQL
  !val.present?
end

def load_person_attribute_types_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_person_attribute_types.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def person_attribute_type_moved_to(person_attribute_type)
  # find person_attribute_type with the old name else create one
  person_attribute_type_in_mahis = PersonAttributeType.find_by_name(person_attribute_type.name&.strip)
  if person_attribute_type_in_mahis.present?
    return OpenStruct.new(person_attribute_type_id: person_attribute_type_in_mahis.person_attribute_type_id, name: person_attribute_type_in_mahis.name)
  end

  # create a new person_attribute_type
  new_person_attribute_type = PersonAttributeType.create(
    name: person_attribute_type.name,
    description: person_attribute_type.name,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_person_attribute_type.reload

  OpenStruct.new(person_attribute_type_id: new_person_attribute_type.person_attribute_type_id, name: person_attribute_type.name)
end


def remap_person_attribute_types
  ActiveRecord::Base.transaction do
    load_person_attribute_types_file.each do |person_attribute_type|
      if person_attribute_type_has_changed?(person_attribute_type)
        moved_person_attribute_type = person_attribute_type_moved_to(person_attribute_type)
        
        log "PersonAttributeType #{person_attribute_type.person_attribute_type_id} (#{person_attribute_type.name}) has changed to #{moved_person_attribute_type.person_attribute_type_id} (#{moved_person_attribute_type.name})"
        
        update_references(person_attribute_type, moved_person_attribute_type, 'person_attribute_types')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
