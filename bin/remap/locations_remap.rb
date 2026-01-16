def mahis_location_from_source(source_location_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT location_id, name 
    FROM location
    WHERE location_id = #{source_location_id}
  SQL
end

def location_has_changed?(location)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM location 
      WHERE location_id = #{location.location_id} 
    AND name = #{quote(location.name)}
  SQL
  !val.present?
end

def load_locations_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_locations.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def location_moved_to(location)
  # find location with the old name else create one
  location_in_mahis = Location.find_by_name(location.name&.strip)
  if location_in_mahis.present?
    return OpenStruct.new(location_id: location_in_mahis.location_id, name: location_in_mahis.name)
  end

  # create a new location
  new_location = Location.create(
    name: location.name,
    description: location.name,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_location.reload

  OpenStruct.new(location_id: new_location.location_id, name: new_location.name)
end


def remap_locations
  ActiveRecord::Base.transaction do
    load_locations_file.each do |location|
      if location_has_changed?(location)
        moved_location = location_moved_to(location)
        
        log "Location #{location.location_id} (#{location.name}) has changed to #{moved_location.location_id} (#{moved_location.name})"
        
        update_references(location, moved_location, 'locations')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
