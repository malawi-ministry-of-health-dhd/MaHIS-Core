def mahis_encounter_type_from_source(source_encounter_type_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT encounter_type_id, name 
    FROM encounter_type
    WHERE encounter_type_id = #{source_encounter_type_id}
  SQL
end

def encounter_type_has_changed?(encounter_type)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM encounter_type 
      WHERE encounter_type_id = #{encounter_type.encounter_type_id} 
    AND name = #{quote(encounter_type.name)}
  SQL
  !val.present?
end

def load_encounter_types_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_encounter_types.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def encounter_type_moved_to(encounter_type)
  # find encounter_type with the old name else create one
  encounter_type_in_mahis = EncounterType.find_by_name(encounter_type.name&.strip)
  if encounter_type_in_mahis.present?
    return OpenStruct.new(encounter_type_id: encounter_type_in_mahis.encounter_type_id, name: encounter_type_in_mahis.name)
  end

  # create a new encounter_type
  new_encounter_type = EncounterType.create(
    name: encounter_type.name,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_encounter_type.reload

  OpenStruct.new(encounter_type_id: new_encounter_type.encounter_type_id, name: encounter_type.name)
end


def remap_encounter_types
  ActiveRecord::Base.transaction do
    load_encounter_types_file.each do |encounter_type|
      if encounter_type_has_changed?(encounter_type)
        moved_encounter_type = encounter_type_moved_to(encounter_type)
        
        log "EncounterType #{encounter_type.encounter_type_id} (#{encounter_type.name}) has changed to #{moved_encounter_type.encounter_type_id} (#{moved_encounter_type.name})"
        
        update_references(encounter_type, moved_encounter_type, 'encounter_types')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
