# frozen_string_literal: true

require 'yaml'

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

# -------------------------------------------------------------------
# Load OpenMRS skeleton database
# -------------------------------------------------------------------
if ENV['INITIAL_SETUP']
  cmd = "gunzip -c db/mahis_skeleton.sql.gz | mysql -u #{username}"
  cmd += " -p#{password}" if password.present?
  cmd += " -h #{host}" if host.present?
  cmd += " -P #{port}" if port.present?
  cmd += " #{database}"

  system(cmd)

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
    cmd = "gunzip -c #{file_path} | mysql -u #{username}"
    cmd += " -p#{password}" if password.present?
    cmd += " -h #{host}" if host.present?
    cmd += " -P #{port}" if port.present?
    cmd += " #{database}"

    system(cmd)

    puts "Imported data from #{File.basename(file_path)}"
  end
else
  puts 'No additional data files to import'
end

ensure_facility_level_data!

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
