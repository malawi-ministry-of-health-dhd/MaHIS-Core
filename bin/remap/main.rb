require 'active_record'
require 'csv'
require 'yaml'
require 'securerandom'

# verbose logging
ActiveRecord::Base.logger = Logger.new($stdout)
LOGGER = Logger.new($stdout)

REMAP_TABLES_FILE = Rails.root.join('bin', 'remap', 'remap_tables.yml')

def initialize_script
  if File.exist?(REMAP_TABLES_FILE)
    @remap_tables = YAML.load_file(REMAP_TABLES_FILE)
  else
    raise "File not found: #{REMAP_TABLES_FILE}"
  end
  @creator = User.first.user_id
end

class MasHISCoreDB < ApplicationRecord
  self.abstract_class = true
  connects_to database: { writing: :primary } # comes from database.yml
end

class SourceDB < ApplicationRecord
  self.abstract_class = true
  connects_to database: { writing: :source_db }
end

def log(message)
  LOGGER.info "\n============================================\n #{message} ... \n============================================"
end

def mahis_core
  MasHISCoreDB.connection.current_database
end

def source_db
  SourceDB.connection.current_database
end

def table_pk(table:)
  SourceDB.connection.select_one("SHOW KEYS FROM #{table} WHERE Key_name = 'PRIMARY'")['Column_name']
end

def mahis_concept_from_source(source_concept_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT concept_id, name 
    FROM concept_name
    WHERE concept_id = #{source_concept_id}
  SQL
end

def quote(value)
  MasHISCoreDB.connection.quote(value)
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

def update_references(old_concept, new_concept, section)
  @remap_tables[section].each do |table, columns|
    columns.each do |column|
      log "Updating #{table} #{old_concept.concept_id} (#{column}) to point to new concept #{new_concept.concept_id} (#{new_concept.name})"
      MasHISCoreDB.connection.execute <<~SQL
        UPDATE #{table} SET #{column} = #{new_concept.concept_id} WHERE #{column} = #{old_concept.concept_id}
      SQL
    end
  end
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

initialize_script
%i[concepts].each do |section|
  send("remap_#{section}")
end