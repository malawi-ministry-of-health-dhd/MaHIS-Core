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

if total > 0
  files.each_with_index do |file_path, idx|
    puts "Importing file #{idx + 1}/#{total}: #{File.basename(file_path)}..."
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
