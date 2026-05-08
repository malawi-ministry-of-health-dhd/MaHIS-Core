# frozen_string_literal: true

require 'yaml'
require 'open-uri'
require 'fileutils'

if ENV['INITIAL_SETUP']
  puts "\e[31mWARNING: This will wipe out your database. Do you want to continue? (y/N)\e[0m"
  response = $stdin.gets.chomp.downcase
  response = 'n' if response.empty?

  unless response == 'y'
    puts 'Database initialization cancelled.'
    exit 0
  end
end

db_config = YAML.load_file(
  Rails.root.join('config', 'database.yml'),
  aliases: true
)[Rails.env]

username = db_config['username']
password = db_config['password']
database = db_config['database']
host     = db_config['host']
port     = db_config['port']

GITHUB_METADATA_URL = ENV.fetch(
  'GITHUB_METADATA_URL',
  'https://raw.githubusercontent.com/malawi-ministry-of-health-dhd/MaHIS-Metadata/main/metadata.sql'
).freeze

SEED_CONCEPT_WORD_STOP_WORDS = %w[A AND AT BUT BY FOR HAS OF THE TO].freeze
SEED_CONCEPT_WORD_REGEX_LARGE = /[!"#$%&'()*,+\-.\/:;<=>?@\[\]\\^_`{|}~]/
SEED_CONCEPT_WORD_REGEX_SMALL = /[!"#$%&'()*,.\/:;<=>?@\[\]\\^_`{|}~]/

def mysql_import_command(username:, password:, host:, port:, database:)
  command = ['mysql', '-u', username.to_s]
  command << "--password=#{password}" if password.present?
  command += ['-h', host.to_s] if host.present?
  command += ['-P', port.to_s] if port.present?
  command << database.to_s
  command
end

def fetch_metadata_from_github!(url, local_path)
  FileUtils.mkdir_p(local_path.dirname)

  puts "Downloading latest metadata from GitHub..."
  URI.open(url, open_timeout: 30, read_timeout: 300) do |remote|
    File.open(local_path, 'wb') do |file|
      IO.copy_stream(remote, file)
    end
  end

  raise "Downloaded file is empty: #{local_path}" unless File.exist?(local_path) && File.size(local_path).positive?

  puts "Metadata downloaded to #{local_path}"
end

def apply_metadata_compatibility_fixes!(file_path)
  conn = ActiveRecord::Base.connection
  changed = false

  concept_map_type_id_type = conn.select_value(<<~SQL)
    SELECT c.COLUMN_TYPE
    FROM information_schema.KEY_COLUMN_USAGE k
    INNER JOIN information_schema.COLUMNS c
      ON c.TABLE_SCHEMA = k.TABLE_SCHEMA
     AND c.TABLE_NAME = k.TABLE_NAME
     AND c.COLUMN_NAME = k.COLUMN_NAME
    WHERE k.TABLE_SCHEMA = DATABASE()
      AND k.REFERENCED_TABLE_NAME = 'concept_map_type'
      AND k.REFERENCED_COLUMN_NAME = 'concept_map_type_id'
    ORDER BY (k.TABLE_NAME = 'concept_reference_map') DESC, k.TABLE_NAME
    LIMIT 1
  SQL

  concept_map_type_id_type ||= conn.select_value(<<~SQL)
    SELECT COLUMN_TYPE
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'concept_map_type'
      AND COLUMN_NAME = 'concept_map_type_id'
    LIMIT 1
  SQL

  sql = File.read(file_path)

  if concept_map_type_id_type.present?
    updated_sql = sql.gsub(
      /(`concept_map_type_id`\s+)(?:int(?:\(\d+\))?(?: unsigned)?|bigint(?:\(\d+\))?(?: unsigned)?)(?=\s)/i,
      "\\1#{concept_map_type_id_type}"
    )

    if updated_sql != sql
      sql = updated_sql
      changed = true
      puts "Applied metadata compatibility fix: aligned concept_map_type_id column type to #{concept_map_type_id_type}"
    end
  end

  unnamed_fk_sql = sql.gsub(/CONSTRAINT\s+`[^`]+`\s+FOREIGN KEY/i, 'FOREIGN KEY')
  if unnamed_fk_sql != sql
    sql = unnamed_fk_sql
    changed = true
    puts 'Applied metadata compatibility fix: removed explicit foreign-key names.'
  end

  return unless changed

  File.write(file_path, sql)
end

def import_sql_file!(file_path:, username:, password:, host:, port:, database:)
  raise "SQL file not found: #{file_path}" unless File.exist?(file_path)

  command = mysql_import_command(
    username: username,
    password: password,
    host: host,
    port: port,
    database: database
  )

  return if system(*command, in: file_path.to_s)

  exit_code = $?.respond_to?(:exitstatus) ? $?.exitstatus : 'unknown'
  raise "Import failed for #{File.basename(file_path)} (exit code: #{exit_code})"
end

def concept_word_parts(phrase, locale)
  return [] if phrase.blank?

  normalized_phrase = phrase.to_s.gsub(
    phrase.to_s.length > 2 ? SEED_CONCEPT_WORD_REGEX_LARGE : SEED_CONCEPT_WORD_REGEX_SMALL,
    ' '
  )

  normalized_phrase
    .strip
    .tr("\n", ' ')
    .split
    .each_with_object([]) do |part, parts|
      word = part.strip.upcase
      next if word.blank?
      next if (locale.blank? || locale.to_s.start_with?('en')) && SEED_CONCEPT_WORD_STOP_WORDS.include?(word)
      next if parts.include?(word)

      parts << word
    end
end

def concept_word_weight(name:, word:, concept_name_type:, locale_preferred:)
  concept_name = name.to_s.upcase
  return 0.0 unless concept_name.include?(word)

  weight = 1.0
  word_length = [word.length, 1].max.to_f
  name_length = [concept_name.length, 1].max.to_f
  name_type = concept_name_type.to_s
  preferred = locale_preferred.to_i == 1

  bonus = lambda do |coefficient|
    type_bonus =
      if name_type == 'INDEX_TERM' || (preferred && name_type == 'FULLY_SPECIFIED')
        coefficient * 0.25
      elsif preferred
        coefficient * 0.24
      elsif name_type == 'FULLY_SPECIFIED'
        coefficient * 0.23
      elsif name_type.blank?
        coefficient * 0.22
      elsif name_type == 'SHORT'
        coefficient * 0.21
      else
        0.0
      end

    type_bonus + (coefficient / name_length)
  end

  if concept_name == word
    coefficient = 5.0
    weight += coefficient
    coefficient += coefficient / word_length
    weight += coefficient / word_length
  elsif concept_name.start_with?(word)
    coefficient = 3.0
    weight += coefficient / word_length
  else
    coefficient = 1.0
    word_index = concept_name.index(word) || 0
    weight += (coefficient / (word_index + 1)) * ((name_length - word_length) / name_length)
  end

  weight + bonus.call(coefficient)
end

def rebuild_concept_word_index!
  conn = ActiveRecord::Base.connection
  foreign_key_checks_changed = false
  return unless conn.table_exists?(:concept_word) && conn.table_exists?(:concept_name) && conn.table_exists?(:concept)

  puts 'Rebuilding concept name search index...'

  previous_foreign_key_checks = conn.select_value('SELECT @@FOREIGN_KEY_CHECKS')
  conn.execute('SET FOREIGN_KEY_CHECKS=0')
  foreign_key_checks_changed = true

  indexed_words = 0

  ActiveRecord::Base.transaction do
    conn.execute('DELETE FROM concept_word')
    conn.execute('ALTER TABLE concept_word AUTO_INCREMENT = 1')

    concept_names = conn.select_all(<<~SQL)
      SELECT
        cn.concept_name_id,
        cn.concept_id,
        cn.name,
        cn.locale,
        cn.concept_name_type,
        cn.locale_preferred
      FROM concept_name cn
      INNER JOIN concept c ON c.concept_id = cn.concept_id
      WHERE COALESCE(cn.voided, 0) = 0
      ORDER BY cn.concept_name_id
    SQL

    values = []
    concept_names.each do |row|
      locale = row['locale'].to_s

      concept_word_parts(row['name'], locale).each do |word|
        indexed_words += 1
        values << [
          row['concept_id'].to_i,
          conn.quote(word[0, 50]),
          conn.quote(locale),
          row['concept_name_id'].to_i,
          format(
            '%.12f',
            concept_word_weight(
              name: row['name'],
              word: word[0, 50],
              concept_name_type: row['concept_name_type'],
              locale_preferred: row['locale_preferred']
            )
          )
        ]

        next if values.size < 1_000

        conn.execute <<~SQL
          INSERT INTO concept_word (concept_id, word, locale, concept_name_id, weight)
          VALUES #{values.map { |value| "(#{value.join(', ')})" }.join(', ')}
        SQL
        values.clear
      end
    end

    if values.any?
      conn.execute <<~SQL
        INSERT INTO concept_word (concept_id, word, locale, concept_name_id, weight)
        VALUES #{values.map { |value| "(#{value.join(', ')})" }.join(', ')}
      SQL
    end
  end
ensure
  if defined?(conn) && conn && foreign_key_checks_changed
    conn.execute("SET FOREIGN_KEY_CHECKS=#{previous_foreign_key_checks || 1}")
  end
  puts "Concept name search index rebuilt with #{indexed_words} words" if defined?(indexed_words)
end

def ensure_facility_level_data!
  conn = ActiveRecord::Base.connection
  required_tables = %w[users location_attribute_type location_attribute]
  return unless required_tables.all? { |table_name| conn.table_exists?(table_name) }

  creator_id = conn.select_value('SELECT user_id FROM users ORDER BY user_id ASC LIMIT 1')
  return if creator_id.blank?

  facility_type_type_id = conn.select_value(<<~SQL)
    SELECT location_attribute_type_id
    FROM location_attribute_type
    WHERE name = 'Facility Type'
    LIMIT 1
  SQL
  return if facility_type_type_id.blank?

  facility_level_type_id = conn.select_value(<<~SQL)
    SELECT location_attribute_type_id
    FROM location_attribute_type
    WHERE name = 'Facility Level'
    LIMIT 1
  SQL

  unless facility_level_type_id.present?
    conn.execute <<~SQL
      INSERT INTO location_attribute_type (
        name,
        datatype,
        creator,
        date_created,
        retired,
        uuid
      )
      VALUES (
        'Facility Level',
        'string',
        #{creator_id.to_i},
        NOW(),
        0,
        UUID()
      )
    SQL

    facility_level_type_id = conn.select_value(<<~SQL)
      SELECT location_attribute_type_id
      FROM location_attribute_type
      WHERE name = 'Facility Level'
      LIMIT 1
    SQL
  end

  conn.execute <<~SQL
    UPDATE location_attribute level_attr
    INNER JOIN location_attribute facility_type_attr
      ON facility_type_attr.location_id = level_attr.location_id
    SET level_attr.value_reference = CASE
          WHEN LOWER(TRIM(facility_type_attr.value_reference)) IN ('health centre', 'health center') THEN 'Primary'
          WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'district hospital' THEN 'Secondary'
          WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'central hospital' THEN 'Tertiary'
        END,
        level_attr.voided = 0,
        level_attr.changed_by = COALESCE(level_attr.changed_by, facility_type_attr.creator),
        level_attr.date_changed = NOW()
    WHERE level_attr.attribute_type_id = #{facility_level_type_id.to_i}
      AND facility_type_attr.attribute_type_id = #{facility_type_type_id.to_i}
      AND COALESCE(level_attr.voided, 0) = 0
      AND COALESCE(facility_type_attr.voided, 0) = 0
      AND (
        level_attr.value_reference IS NULL
        OR TRIM(level_attr.value_reference) = ''
      )
      AND LOWER(TRIM(facility_type_attr.value_reference)) IN (
        'health centre',
        'health center',
        'district hospital',
        'central hospital'
      )
  SQL

  conn.execute <<~SQL
    INSERT INTO location_attribute (
      location_id,
      attribute_type_id,
      value_reference,
      uuid,
      creator,
      date_created,
      voided
    )
    SELECT
      facility_type_attr.location_id,
      #{facility_level_type_id.to_i},
      CASE
        WHEN LOWER(TRIM(facility_type_attr.value_reference)) IN ('health centre', 'health center') THEN 'Primary'
        WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'district hospital' THEN 'Secondary'
        WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'central hospital' THEN 'Tertiary'
      END,
      UUID(),
      COALESCE(facility_type_attr.creator, #{creator_id.to_i}),
      COALESCE(facility_type_attr.date_created, NOW()),
      0
    FROM location_attribute facility_type_attr
    LEFT JOIN location_attribute level_attr
      ON level_attr.location_id = facility_type_attr.location_id
      AND level_attr.attribute_type_id = #{facility_level_type_id.to_i}
    WHERE facility_type_attr.attribute_type_id = #{facility_type_type_id.to_i}
      AND COALESCE(facility_type_attr.voided, 0) = 0
      AND LOWER(TRIM(facility_type_attr.value_reference)) IN (
        'health centre',
        'health center',
        'district hospital',
        'central hospital'
      )
      AND level_attr.location_attribute_id IS NULL
  SQL
end

begin
  tmp_file = Rails.root.join('tmp', 'metadata.sql')

  fetch_metadata_from_github!(GITHUB_METADATA_URL, tmp_file)
  apply_metadata_compatibility_fixes!(tmp_file)

  import_sql_file!(
    file_path: tmp_file,
    username: username,
    password: password,
    host: host,
    port: port,
    database: database
  )

  puts 'GitHub metadata import complete.'
rescue StandardError => e
  raise "Failed to import metadata from GitHub: #{e.message}"
end

local_sql_files = Dir.glob(Rails.root.join('db', 'data', '*.sql')).sort

if local_sql_files.any?
  local_sql_files.each_with_index do |file_path, idx|
    puts "Importing local SQL file #{idx + 1}/#{local_sql_files.size}: #{File.basename(file_path)}..."

    next if File.basename(file_path) == 'locations.sql' &&
            defined?(Location) &&
            Location.table_exists? &&
            Location.count.positive?

    import_sql_file!(
      file_path: file_path,
      username: username,
      password: password,
      host: host,
      port: port,
      database: database
    )
  end
else
  puts 'No additional local .sql files to import in db/data.'
end

ensure_facility_level_data!
rebuild_concept_word_index!

if defined?(Role) && defined?(UserRole) && Role.table_exists? && UserRole.table_exists?
  roles = Role.where(role: ['Superuser', 'Global Superuser'])
  roles.each { |role| UserRole.find_or_create_by!(user_id: 2, role: role) }
else
  puts 'Skipping role assignment: required tables are missing.'
end

puts <<~MSG
  ----------------------------------------
  Database seeding complete
  ----------------------------------------
  System user:
    username: daemon
    password: daemon

  Admin user:
    username: admin
    password: Admin123
    role:     Superuser
  ----------------------------------------
MSG
