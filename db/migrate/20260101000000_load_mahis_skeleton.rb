# frozen_string_literal: true

require 'yaml'

class LoadMahisSkeleton < ActiveRecord::Migration[7.0]
  def up
    # Load database configuration
    db_config = YAML.load_file(
      Rails.root.join('config', 'database.yml'),
      aliases: true
    )[Rails.env]

    username = db_config['username']
    password = db_config['password']
    database = db_config['database']
    host     = db_config['host']
    port     = db_config['port']

    # Load OpenMRS skeleton database
    cmd = "gunzip -c db/mahis_skeleton.sql.gz | mysql -u #{username}"
    cmd += " -p#{password}" if password.present?
    cmd += " -h #{host}" if host.present?
    cmd += " -P #{port}" if port.present?
    cmd += " #{database}"

    puts 'Loading OpenMRS skeleton...'
    system(cmd)
    puts 'Harmonized DB Initialization Complete 🎉'
  end

  def down
    # Don't drop on rollback - skeleton is foundational
  end
end