def mahis_program_from_source(source_program_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT program_id, name 
    FROM program
    WHERE program_id = #{source_program_id}
  SQL
end

def program_has_changed?(program)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM program 
      WHERE program_id = #{program.program_id} 
    AND name = #{quote(program.name)}
  SQL
  !val.present?
end

def load_programs_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_programs.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def program_moved_to(program)
  # find program with the old name else create one
  program_in_mahis = Program.find_by_name(program.name&.strip)
  if program_in_mahis.present?
    return OpenStruct.new(program_id: program_in_mahis.program_id, name: program_in_mahis.name)
  end

  # create a new program
  # Note: Program requires concept_id - using 1 as default, adjust as needed
  new_program = Program.create(
    name: program.name,
    concept_id: 1,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_program.reload

  OpenStruct.new(program_id: new_program.program_id, name: program.name)
end


def remap_programs
  ActiveRecord::Base.transaction do
    load_programs_file.each do |program|
      if program_has_changed?(program)
        moved_program = program_moved_to(program)
        
        log "Program #{program.program_id} (#{program.name}) has changed to #{moved_program.program_id} (#{moved_program.name})"
        
        update_references(program, moved_program, 'programs')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
