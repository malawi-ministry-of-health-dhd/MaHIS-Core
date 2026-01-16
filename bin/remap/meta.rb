
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

def quote(value)
  MasHISCoreDB.connection.quote(value)
end

def get_id_field(entity, section)
  # Map section names to their ID field names
  id_field_map = {
    'concepts' => 'concept_id',
    'drugs' => 'drug_id',
    'encounter_types' => 'encounter_type_id',
    'programs' => 'program_id',
    'order_types' => 'order_type_id',
    'patient_identifier_types' => 'patient_identifier_type_id',
    'relationship_types' => 'relationship_type_id',
    'user_roles' => 'role',
    'person_attribute_types' => 'person_attribute_type_id'
  }
  
  id_field_map[section] || "#{section.singularize}_id"
end

def update_references(old_entity, new_entity, section)
  id_field = get_id_field(old_entity, section)
  old_id = old_entity.send(id_field)
  new_id = new_entity.send(id_field)
  entity_name = new_entity.respond_to?(:name) ? new_entity.name : new_id
  
  @remap_tables[section].each do |table, columns|
    columns.each do |column|
      log "Updating #{table}.#{column} from #{old_id} to #{new_id} (#{entity_name})"
      
      # Quote values if they are strings (for user roles)
      quoted_old_id = old_id.is_a?(String) ? quote(old_id) : old_id
      quoted_new_id = new_id.is_a?(String) ? quote(new_id) : new_id
      
      MasHISCoreDB.connection.execute <<~SQL
        UPDATE #{table} SET #{column} = #{quoted_new_id} WHERE #{column} = #{quoted_old_id}
      SQL
    end
  end
end