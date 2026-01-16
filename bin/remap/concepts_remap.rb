def mahis_concept_from_source(source_concept_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT concept_id, name 
    FROM concept_name
    WHERE concept_id = #{source_concept_id}
  SQL
end

def concept_has_changed?(concept)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM concept_name 
      WHERE concept_id = #{concept.concept_id} 
    AND name = #{quote(concept.name)}
  SQL
  !val.present?
end

def load_concepts_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_concepts.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def concept_moved_to(concept)
  # find concept and id with the old name else create one
  concept_in_mahis = ConceptName.find_by_name(concept.name&.strip)
  if concept_in_mahis.present?
    return OpenStruct.new(concept_id: concept_in_mahis.concept_id, name: concept_in_mahis.name)
  end

  # create a new concept
  new_concept = Concept.create(
    short_name: concept.name,
    creator: @creator,
    datatype_id: 1,
    class_id: 1,
    is_set: 0,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  ConceptName.create(
    concept_id: new_concept.concept_id,
    name: concept.name,
    creator: @creator,
    locale: 'en',
    voided: 0,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_concept.reload

  OpenStruct.new(concept_id: new_concept.concept_id, name: concept.name)
end


def remap_concepts
  ActiveRecord::Base.transaction do
    load_concepts_file.each do |concept|
      if concept_has_changed?(concept)
        updated_concept = mahis_concept_from_source(concept['concept_id'])
        
        log "Concept #{concept.concept_id} (#{concept.name}) has changed to #{updated_concept['concept_id']} (#{updated_concept['name']})"
        
        update_references(concept, concept_moved_to(concept), 'concepts')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end