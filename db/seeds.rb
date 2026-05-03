# frozen_string_literal: true

require 'yaml'
require 'shellwords'

# -------------------------------------------------------------------
# Load database configuration
# -------------------------------------------------------------------
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

def import_sql_gz!(file_path:, username:, password:, host:, port:, database:)
  source_cmd = "gunzip -c #{Shellwords.escape(file_path.to_s)}"

  cmd = "#{source_cmd} | mysql -u #{Shellwords.escape(username.to_s)}"
  cmd += " -p#{Shellwords.escape(password.to_s)}" if password.present?
  cmd += " -h #{Shellwords.escape(host.to_s)}" if host.present?
  cmd += " -P #{Shellwords.escape(port.to_s)}" if port.present?
  cmd += " #{Shellwords.escape(database.to_s)}"

  return if system(cmd)

  exit_code = $?.respond_to?(:exitstatus) ? $?.exitstatus : 'unknown'
  raise "Import failed for #{File.basename(file_path)} (exit code: #{exit_code})"
end

def ensure_facility_level_data!
  conn = ActiveRecord::Base.connection
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

CONCEPT_WORD_STOP_WORDS = %w[A AND AT BUT BY FOR HAS OF THE TO].freeze
CONCEPT_WORD_REGEX_LARGE = /[!"#$%&'()*,+\-.\/:;<=>?@\[\]\\^_`{|}~]/
CONCEPT_WORD_REGEX_SMALL = /[!"#$%&'()*,.\/:;<=>?@\[\]\\^_`{|}~]/

def concept_word_parts(phrase, locale)
  return [] if phrase.blank?

  normalized_phrase = phrase.to_s.gsub(
    phrase.to_s.length > 2 ? CONCEPT_WORD_REGEX_LARGE : CONCEPT_WORD_REGEX_SMALL,
    ' '
  )

  normalized_phrase
    .strip
    .tr("\n", ' ')
    .split
    .each_with_object([]) do |part, parts|
      word = part.strip.upcase
      next if word.blank?
      next if (locale.blank? || locale.to_s.start_with?('en')) && CONCEPT_WORD_STOP_WORDS.include?(word)
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

# -------------------------------------------------------------------
# Load OpenMRS skeleton database
# -------------------------------------------------------------------
if ENV['INITIAL_SETUP']
  import_sql_gz!(
    file_path: Rails.root.join('db', 'mahis_skeleton.sql.gz'),
    username: username,
    password: password,
    host: host,
    port: port,
    database: database
  )

  puts 'Harmonized DB Initialization Complete 🎉'
end

# -----------------------------------------------------------
# Loop through db/data, get all .sql.gz and import them
# (Skeleton is loaded via migration, not in seeds)
# -----------------------------------------------------------
files = Dir.glob(Rails.root.join('db', 'data', '*.sql.gz'))
total = files.size

if total.positive?
  files.each_with_index do |file_path, idx|
    puts "Importing file #{idx + 1}/#{total}: #{File.basename(file_path)}..."
    if File.basename(file_path) == 'locations.sql.gz' && Location.count.positive?
      puts <<~DOC
        DOCSkipping adding of location meta-data because locations is#{' '}
        not empty might overwrite custom locations created ask admin to sync
        and additional locations you might need.
      DOC
      next
    end
    import_sql_gz!(
      file_path: file_path,
      username: username,
      password: password,
      host: host,
      port: port,
      database: database
    )

    puts "Imported data from #{File.basename(file_path)}"
  end
else
  puts 'No additional data files to import'
end

ensure_facility_level_data!
rebuild_concept_word_index!

roles = Role.where(role: ['Superuser', 'Global Superuser'])

roles.each { |role| UserRole.find_or_create_by!(user_id: 2, role: role) }

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
