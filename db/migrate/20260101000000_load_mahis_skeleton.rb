# frozen_string_literal: true

require 'open3'

class LoadMahisSkeleton < ActiveRecord::Migration[7.0]
  def up
    db_config = ActiveRecord::Base.connection_db_config.configuration_hash.stringify_keys
    unless db_config['adapter'] == 'mysql2'
      raise "OpenMRS skeleton import requires the mysql2 adapter, got #{db_config['adapter'].inspect}"
    end

    database = db_config['database']
    raise 'OpenMRS skeleton import requires a database name' if database.blank?

    puts 'Loading OpenMRS skeleton...'

    skeleton_path = Rails.root.join('db', 'mahis_skeleton.sql.gz')
    raise "OpenMRS skeleton not found at #{skeleton_path}" unless File.exist?(skeleton_path)

    mysql_command = ['mysql']
    mysql_command.concat(['--user', db_config['username'].to_s]) if db_config['username'].present?
    mysql_command.concat(['--host', db_config['host'].to_s]) if db_config['host'].present?
    mysql_command.concat(['--port', db_config['port'].to_s]) if db_config['port'].present?
    mysql_command << database.to_s

    mysql_env = {}
    mysql_env['MYSQL_PWD'] = db_config['password'].to_s if db_config['password'].present?

    gunzip_status, mysql_status = Open3.pipeline(
      ['gunzip', '-c', skeleton_path.to_s],
      [mysql_env, *mysql_command]
    )

    unless gunzip_status.success? && mysql_status.success?
      raise "OpenMRS skeleton import failed " \
            "(gunzip exit=#{gunzip_status.exitstatus.inspect}, mysql exit=#{mysql_status.exitstatus.inspect})"
    end

    puts 'Harmonized DB Initialization Complete 🎉'
  end

  def down
    # Don't drop on rollback - skeleton is foundational
  end
end
