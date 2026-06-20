# frozen_string_literal: true

require 'rubygems/version'

module TidbSupport
  MINIMUM_VERSION = Gem::Version.new('8.5.0')
  VERSION_PATTERN = /TiDB(?:-v)?(\d+\.\d+\.\d+)/i

  module_function

  def enabled?(connection = default_connection)
    return true if version_string(connection).match?(/tidb/i)

    env_enabled?
  rescue StandardError
    env_enabled?
  end

  def version(connection = default_connection)
    match = version_string(connection).match(VERSION_PATTERN)
    match && Gem::Version.new(match[1])
  end

  def supported?(connection = default_connection)
    detected_version = version(connection)
    detected_version && detected_version >= MINIMUM_VERSION
  end

  def verify_supported!(connection = default_connection)
    return unless enabled?(connection)

    detected_version = version(connection)
    return if detected_version && detected_version >= MINIMUM_VERSION

    raise "MAHIS requires TiDB #{MINIMUM_VERSION} or newer; server reported #{version_string(connection).inspect}"
  end

  def version_string(connection = default_connection)
    connection.select_value('SELECT VERSION()').to_s
  end

  def env_enabled?
    %w[1 true yes on].include?(ENV.fetch('TIDB_ENABLED', '').downcase)
  end

  def default_connection
    ActiveRecord::Base.connection
  end
end
