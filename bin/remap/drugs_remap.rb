def load_drugs_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_drugs.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def drug_has_changed?(drug)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM drug 
      WHERE drug_id = #{drug.drug_id} 
    AND name = #{quote(drug.name)}
  SQL
  !val.present?
end

def drug_moved_to(drug)
  # find drug and id with the old name else create one
  drug_in_mahis = Drug.find_by_name(drug.name&.strip)
  if drug_in_mahis.present?
    return OpenStruct.new(drug_id: drug_in_mahis.drug_id, name: drug_in_mahis.name)
  end

  # create a new drug
  # Note: Drug requires concept_id - using 1 as default, adjust as needed
  # Using unscoped to bypass retired scope during creation
  new_drug = Drug.unscoped.new(
    name: drug.name,
    concept_id: 1,
    retired: 0,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_drug.save(validate: false)
  new_drug.reload

  OpenStruct.new(drug_id: new_drug.drug_id, name: new_drug.name)
end

def remap_drugs
  ActiveRecord::Base.transaction do
    load_drugs_file.each do |drug|
      if drug_has_changed?(drug)
        moved_drug = drug_moved_to(drug)
        log "Drug #{drug.drug_id} (#{drug.name}) has changed to #{moved_drug.drug_id} (#{moved_drug.name})"
        update_references(drug, moved_drug, 'drugs')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
