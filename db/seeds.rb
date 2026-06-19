# frozen_string_literal: true

require 'yaml'
require 'open-uri'
require 'fileutils'
require 'digest/sha1'
require 'securerandom'
require 'shellwords'
require 'tempfile'

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

  import_path = prepare_sql_for_import(file_path)
  command = mysql_import_command(
    username: username,
    password: password,
    host: host,
    port: port,
    database: database
  )

  return if system(*command, in: import_path)

  exit_code = $?.respond_to?(:exitstatus) ? $?.exitstatus : 'unknown'
  raise "Import failed for #{File.basename(file_path)} (exit code: #{exit_code})"
ensure
  cleanup_prepared_sql_file!(original_path: file_path, prepared_path: import_path)
end

def import_sql_or_gzip_file!(file_path:, username:, password:, host:, port:, database:)
  file_path = file_path.to_s
  raise "SQL file not found: #{file_path}" unless File.exist?(file_path)

  unless File.extname(file_path) == '.gz'
    return import_sql_file!(
      file_path: file_path,
      username: username,
      password: password,
      host: host,
      port: port,
      database: database
    )
  end

  tmp_file = Tempfile.new(['seed_import_', '.sql'], Rails.root.join('tmp'))
  tmp_file.close

  command = <<~BASH
    set -o pipefail
    gunzip -c #{Shellwords.escape(file_path)} > #{Shellwords.escape(tmp_file.path)}
  BASH

  unless system('bash', '-lc', command)
    exit_code = $?.respond_to?(:exitstatus) ? $?.exitstatus : 'unknown'
    raise "Failed to decompress #{File.basename(file_path)} (exit code: #{exit_code})"
  end

  import_sql_file!(
    file_path: tmp_file.path,
    username: username,
    password: password,
    host: host,
    port: port,
    database: database
  )
ensure
  tmp_file&.unlink if defined?(tmp_file) && tmp_file && File.exist?(tmp_file.path)
end

def strip_definer_clauses(sql)
  sql.gsub(/\bDEFINER\s*=\s*`[^`]+`@`[^`]+`\s*/i, '')
end

def prepare_sql_for_import(file_path)
  file_path = file_path.to_s
  sql = File.read(file_path)
  sanitized_sql = strip_definer_clauses(sql)
  return file_path if sanitized_sql == sql

  FileUtils.mkdir_p(Rails.root.join('tmp'))
  sanitized_file = Tempfile.new(['seed_sanitized_', '.sql'], Rails.root.join('tmp'))
  sanitized_file.write(sanitized_sql)
  sanitized_file.flush
  sanitized_file.close

  puts "Sanitized DEFINER clauses for #{File.basename(file_path)}."
  sanitized_file.path
end

def cleanup_prepared_sql_file!(original_path:, prepared_path:)
  return if prepared_path.nil? || prepared_path.to_s.empty?
  return if original_path.to_s == prepared_path.to_s
  return unless File.exist?(prepared_path.to_s)

  File.delete(prepared_path.to_s)
end

def routine_exists?(routine_name)
  ActiveRecord::Base.uncached do
    conn = ActiveRecord::Base.connection
    conn.select_value(<<~SQL).to_i.positive?
      SELECT COUNT(*)
      FROM information_schema.ROUTINES
      WHERE ROUTINE_SCHEMA = DATABASE()
        AND ROUTINE_NAME = #{conn.quote(routine_name)}
    SQL
  end
end

def import_routines_from_skeleton!(skeleton_path:, username:, password:, host:, port:, database:)
  skeleton_path = skeleton_path.to_s
  raise "Skeleton SQL file not found: #{skeleton_path}" unless File.exist?(skeleton_path)

  mysql_cmd = Shellwords.join(
    mysql_import_command(
      username: username,
      password: password,
      host: host,
      port: port,
      database: database
    )
  )

  command = <<~BASH
    set -o pipefail
    gunzip -c #{Shellwords.escape(skeleton_path)} |
      awk '
        /^\\/\\*!50003 DROP (FUNCTION|PROCEDURE) IF EXISTS/ {capture=1}
        capture {print}
        capture && /^\\/\\*!50003 SET collation_connection[[:space:]]*=[[:space:]]*@saved_col_connection[[:space:]]*\\*\\/[[:space:]]*;/ {capture=0}
      ' |
      sed -E 's/DEFINER[[:space:]]*=[[:space:]]*`[^`]+`@`[^`]+`[[:space:]]*//g' |
      #{mysql_cmd}
  BASH

  return if system('bash', '-lc', command)

  exit_code = $?.respond_to?(:exitstatus) ? $?.exitstatus : 'unknown'
  raise "Routine import failed from #{File.basename(skeleton_path)} (exit code: #{exit_code})"
end

def extract_routine_blocks_from_skeleton(skeleton_path:, routine_names:)
  return [] if routine_names.blank?

  routine_names_downcase = routine_names.map { |name| name.to_s.downcase }.uniq
  blocks = []
  current_lines = []
  capturing = false
  current_routine = nil

  IO.popen(['gunzip', '-c', skeleton_path.to_s], 'r') do |io|
    io.each_line do |line|
      if !capturing
        match = line.match(%r{^/\*!50003 DROP (FUNCTION|PROCEDURE) IF EXISTS `([^`]+)` \*/;})
        next unless match

        routine_name = match[2].to_s.downcase
        next unless routine_names_downcase.include?(routine_name)

        capturing = true
        current_routine = routine_name
        current_lines = [line]
        next
      end

      current_lines << line

      next unless line.match?(%r{^/\*!50003 SET collation_connection[[:space:]]*=[[:space:]]*@saved_col_connection[[:space:]]*\*/[[:space:]]*;})

      blocks << current_lines.join if current_routine && routine_names_downcase.include?(current_routine)
      capturing = false
      current_routine = nil
      current_lines = []
    end
  end

  blocks
end

def import_targeted_routines_from_skeleton!(skeleton_path:, routine_names:, username:, password:, host:, port:, database:)
  blocks = extract_routine_blocks_from_skeleton(skeleton_path: skeleton_path, routine_names: routine_names)
  return if blocks.empty?

  sql = strip_definer_clauses(blocks.join("\n"))
  return if sql.blank?

  FileUtils.mkdir_p(Rails.root.join('tmp'))
  tmp_file = Tempfile.new(['targeted_routines_', '.sql'], Rails.root.join('tmp'))
  tmp_file.write(sql)
  tmp_file.flush
  tmp_file.close

  begin
    import_sql_file!(
      file_path: tmp_file.path,
      username: username,
      password: password,
      host: host,
      port: port,
      database: database
    )
  ensure
    tmp_file.unlink if File.exist?(tmp_file.path)
  end
end

def ensure_required_routines!(username:, password:, host:, port:, database:)
  required_routines = %w[
    patient_start_date
    patient_outcome
    current_defaulter_date
  ]
  missing_routines = required_routines.reject { |routine_name| routine_exists?(routine_name) }

  if missing_routines.empty?
    puts 'Required SQL routines already present.'
    return
  end

  skeleton_path = Rails.root.join('db', 'mahis_skeleton.sql.gz')
  unless File.exist?(skeleton_path)
    puts "Missing SQL routines (#{missing_routines.join(', ')}), but #{skeleton_path} was not found."
    return
  end

  puts "Missing SQL routines detected (#{missing_routines.join(', ')}). Loading routines from #{skeleton_path}..."
  import_routines_from_skeleton!(
    skeleton_path: skeleton_path,
    username: username,
    password: password,
    host: host,
    port: port,
    database: database
  )

  still_missing = required_routines.reject { |routine_name| routine_exists?(routine_name) }
  if still_missing.any?
    puts "Routine bootstrap retry: importing missing routines directly (#{still_missing.join(', ')})..."
    import_targeted_routines_from_skeleton!(
      skeleton_path: skeleton_path,
      routine_names: still_missing,
      username: username,
      password: password,
      host: host,
      port: port,
      database: database
    )
  end

  still_missing = required_routines.reject { |routine_name| routine_exists?(routine_name) }
  return if still_missing.empty?

  raise "Routine bootstrap failed. Missing routines after import: #{still_missing.join(', ')}"
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

def ensure_last_password_updated!(conn, user_id)
  return unless conn.table_exists?('user_property')

  exists = conn.select_value(<<~SQL)
    SELECT COUNT(*)
    FROM user_property
    WHERE user_id = #{user_id.to_i}
      AND property = 'last_password_updated'
  SQL

  return unless exists.to_i.zero?

  conn.execute <<~SQL
    INSERT INTO user_property (user_id, property, property_value)
    VALUES (#{user_id.to_i}, 'last_password_updated', #{conn.quote(Time.now.iso8601)})
  SQL
end

def ensure_openmrs_user!(conn:, username:, password:, gender:, location_id:, preferred_user_id: nil, given_name: nil, family_name: nil)
  existing_user_id = conn.select_value(<<~SQL)
    SELECT user_id
    FROM users
    WHERE username = #{conn.quote(username)}
    LIMIT 1
  SQL

  if existing_user_id.present?
    ensure_last_password_updated!(conn, existing_user_id)
    return existing_user_id.to_i
  end

  person_uuid = SecureRandom.uuid
  conn.execute <<~SQL
    INSERT INTO person (gender, creator, date_created, voided, uuid)
    VALUES (#{conn.quote(gender)}, 1, NOW(), 0, #{conn.quote(person_uuid)})
  SQL

  person_id = conn.select_value(<<~SQL).to_i
    SELECT person_id
    FROM person
    WHERE uuid = #{conn.quote(person_uuid)}
    LIMIT 1
  SQL

  if given_name.present? && family_name.present?
    conn.execute <<~SQL
      INSERT INTO person_name
        (person_id, given_name, family_name, preferred, creator, date_created, voided, uuid)
      VALUES
        (
          #{person_id},
          #{conn.quote(given_name)},
          #{conn.quote(family_name)},
          1,
          1,
          NOW(),
          0,
          UUID()
        )
    SQL
  end

  salt = SecureRandom.base64
  password_hash = Digest::SHA1.hexdigest("#{password}#{salt}")

  requested_user_id = preferred_user_id.to_i if preferred_user_id.present?
  use_requested_user_id = requested_user_id.present? &&
                          conn.select_value("SELECT COUNT(*) FROM users WHERE user_id = #{requested_user_id}").to_i.zero?

  user_id_columns = use_requested_user_id ? 'user_id, ' : ''
  user_id_values = use_requested_user_id ? "#{requested_user_id}, " : ''
  location_value = location_id.present? ? conn.quote(location_id.to_s) : 'NULL'

  conn.execute <<~SQL
    INSERT INTO users
      (
        #{user_id_columns}username,
        password,
        salt,
        person_id,
        creator,
        date_created,
        retired,
        uuid,
        location_id
      )
    VALUES
      (
        #{user_id_values}#{conn.quote(username)},
        #{conn.quote(password_hash)},
        #{conn.quote(salt)},
        #{person_id},
        1,
        NOW(),
        0,
        UUID(),
        #{location_value}
      )
  SQL

  user_id = conn.select_value(<<~SQL).to_i
    SELECT user_id
    FROM users
    WHERE username = #{conn.quote(username)}
    LIMIT 1
  SQL

  ensure_last_password_updated!(conn, user_id)
  user_id
end

def ensure_bootstrap_users!
  conn = ActiveRecord::Base.connection
  required_tables = %w[users person]
  unless required_tables.all? { |table_name| conn.table_exists?(table_name) }
    puts 'Skipping default user creation: required tables are missing.'
    return
  end

  previous_foreign_key_checks = conn.select_value('SELECT @@FOREIGN_KEY_CHECKS')
  conn.execute('SET FOREIGN_KEY_CHECKS=0')

  begin
    location_id = if conn.table_exists?('location')
                    conn.select_value('SELECT CAST(location_id AS CHAR) FROM location ORDER BY location_id ASC LIMIT 1')
                  end

    daemon_user_id = ensure_openmrs_user!(
      conn:,
      username: 'daemon',
      password: 'daemon',
      gender: 'U',
      location_id:,
      preferred_user_id: 1
    )

    lab_daemon_user_id = ensure_openmrs_user!(
      conn:,
      username: 'lab_daemon',
      password: 'lab_daemon',
      gender: 'U',
      location_id:
    )

    admin_user_id = ensure_openmrs_user!(
      conn:,
      username: 'admin',
      password: 'Admin123',
      gender: 'M',
      given_name: 'Admin',
      family_name: 'User',
      location_id:
    )

    if conn.table_exists?('role') && conn.table_exists?('user_role')
      role_names = conn.select_values(<<~SQL)
        SELECT role
        FROM role
        WHERE role IN ('Superuser', 'Global Superuser')
      SQL

      if role_names.empty?
        puts 'Skipping admin role assignment: Superuser role not found.'
      else
        role_names.each do |role_name|
          exists = conn.select_value(<<~SQL)
            SELECT COUNT(*)
            FROM user_role
            WHERE user_id = #{admin_user_id}
              AND role = #{conn.quote(role_name)}
          SQL
          next unless exists.to_i.zero?

          conn.execute <<~SQL
            INSERT INTO user_role (user_id, role)
            VALUES (#{admin_user_id}, #{conn.quote(role_name)})
          SQL
        end
      end
    else
      puts 'Skipping admin role assignment: role tables are missing.'
    end

    puts "Default users ensured (daemon user_id=#{daemon_user_id}, lab_daemon user_id=#{lab_daemon_user_id}, admin user_id=#{admin_user_id})."
  ensure
    conn.execute("SET FOREIGN_KEY_CHECKS=#{previous_foreign_key_checks || 1}")
  end
end

local_sql_files = Dir.glob([
  Rails.root.join('db', 'data', '*.sql').to_s,
  Rails.root.join('db', 'data', '*.sql.gz').to_s
]).sort

if local_sql_files.any?
  local_sql_files.each_with_index do |file_path, idx|
    puts "Importing local SQL file #{idx + 1}/#{local_sql_files.size}: #{File.basename(file_path)}..."

    next if %w[locations.sql locations.sql.gz].include?(File.basename(file_path)) &&
            defined?(Location) &&
            Location.table_exists? &&
            Location.count.positive?

    import_sql_or_gzip_file!(
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

ensure_required_routines!(
  username: username,
  password: password,
  host: host,
  port: port,
  database: database
)

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

ensure_facility_level_data!
rebuild_concept_word_index!
ensure_bootstrap_users!
load Rails.root.join('db', 'seeds', 'privileges_seed.rb')
# Must run after privileges_seed.rb so the privilege rows exist before they are
# wired to roles. This idempotent seed creates the standard clinical roles
# (incl. the supervision roles: Student/Intern Nurse & Clinician) and their
# privileges. It lives here in seeds — not only in migrations — because data
# migrations are skipped when a DB is built via `db:schema:load`, which is how
# fresh production DBs are typically created.
load Rails.root.join('db', 'seeds', 'role_privileges_seed.rb')

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
