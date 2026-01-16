def mahis_patient_identifier_type_from_source(source_patient_identifier_type_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT patient_identifier_type_id, name 
    FROM patient_identifier_type
    WHERE patient_identifier_type_id = #{source_patient_identifier_type_id}
  SQL
end

def patient_identifier_type_has_changed?(patient_identifier_type)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM patient_identifier_type 
      WHERE patient_identifier_type_id = #{patient_identifier_type.patient_identifier_type_id} 
    AND name = #{quote(patient_identifier_type.name)}
  SQL
  !val.present?
end

def load_patient_identifier_types_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_patient_identifier_types.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def patient_identifier_type_moved_to(patient_identifier_type)
  # find patient_identifier_type with the old name else create one
  patient_identifier_type_in_mahis = PatientIdentifierType.find_by_name(patient_identifier_type.name&.strip)
  if patient_identifier_type_in_mahis.present?
    return OpenStruct.new(patient_identifier_type_id: patient_identifier_type_in_mahis.patient_identifier_type_id, name: patient_identifier_type_in_mahis.name)
  end

  # create a new patient_identifier_type
  new_patient_identifier_type = PatientIdentifierType.create(
    name: patient_identifier_type.name,
    description: patient_identifier_type.name,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_patient_identifier_type.reload

  OpenStruct.new(patient_identifier_type_id: new_patient_identifier_type.patient_identifier_type_id, name: patient_identifier_type.name)
end


def remap_patient_identifier_types
  ActiveRecord::Base.transaction do
    load_patient_identifier_types_file.each do |patient_identifier_type|
      if patient_identifier_type_has_changed?(patient_identifier_type)
        moved_patient_identifier_type = patient_identifier_type_moved_to(patient_identifier_type)
        
        log "PatientIdentifierType #{patient_identifier_type.patient_identifier_type_id} (#{patient_identifier_type.name}) has changed to #{moved_patient_identifier_type.patient_identifier_type_id} (#{moved_patient_identifier_type.name})"
        
        update_references(patient_identifier_type, moved_patient_identifier_type, 'patient_identifier_types')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
