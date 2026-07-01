# frozen_string_literal: true

require 'erb'
require 'pathname'
require 'yaml'

module MahisUserImport
  class ConfigurationError < StandardError; end

  class ConfigLoader
    CONFIG_PATH = Rails.root.join('config', 'users.yml')
    REQUIRED_KEYS = %w[target_url users_file require_confirmation].freeze

    Config = Struct.new(
      :environment,
      :target_url,
      :admin_username,
      :admin_password,
      :users_file,
      :users_file_path,
      :require_confirmation,
      keyword_init: true
    )

    def initialize(path = CONFIG_PATH)
      @path = Pathname(path)
    end

    def load(environment)
      raise ConfigurationError, missing_config_message unless @path.exist?

      config = YAML.safe_load(ERB.new(@path.read).result, aliases: true) || {}
      env_config = config[environment.to_s]
      raise ConfigurationError, "Missing '#{environment}' block in #{@path}" unless env_config.is_a?(Hash)

      validate_environment_config!(environment.to_s, env_config)
      build_config(environment.to_s, env_config)
    end

    private

    def build_config(environment, env_config)
      users_file = env_config['users_file'].to_s
      users_file_path = Pathname(users_file).absolute? ? Pathname(users_file) : Rails.root.join(users_file)

      Config.new(
        environment: environment,
        target_url: env_config['target_url'].to_s,
        admin_username: env_config.dig('admin', 'username').to_s,
        admin_password: env_config.dig('admin', 'password').to_s,
        users_file: users_file,
        users_file_path: users_file_path,
        require_confirmation: env_config['require_confirmation']
      )
    end

    def validate_environment_config!(environment, env_config)
      errors = []

      REQUIRED_KEYS.each do |key|
        value = env_config[key]
        errors << "Missing required config value '#{key}'" if value.nil? || value.to_s.strip.empty?
      end

      admin = env_config['admin']
      if admin.blank?
        errors << "Missing required config value 'admin'"
      else
        errors << "Missing required config value 'admin.username'" if admin['username'].to_s.strip.empty?
        errors << "Missing required config value 'admin.password'" if admin['password'].to_s.strip.empty?
      end

      unless [true, false].include?(env_config['require_confirmation'])
        errors << "Config value 'require_confirmation' must be true or false"
      end

      if environment == 'production' && env_config['require_confirmation'] != true
        errors << "Production imports must set 'require_confirmation' to true"
      end

      users_file = env_config['users_file'].to_s
      users_file_path = Pathname(users_file).absolute? ? Pathname(users_file) : Rails.root.join(users_file)
      errors << "Excel users_file does not exist: #{users_file}" unless users_file_path.exist?

      raise ConfigurationError, errors.join('; ') if errors.any?
    end

    def missing_config_message
      "Missing #{@path}. Copy config/users.yml.example to config/users.yml and fill in the target details."
    end
  end
end
