# frozen_string_literal: true

namespace :mahis do
  namespace :users do
    desc 'Create MaHIS users from config/users.yml and the configured Excel file'
    task :create, %i[environment dry_run] => :environment do |_task, args|
      environment = args[:environment].presence || Rails.env
      dry_run = ActiveModel::Type::Boolean.new.cast(args[:dry_run])

      runner = MahisUserImport::ImportRunner.new(
        environment: environment,
        dry_run: dry_run
      )
      runner.call
    rescue StandardError => e
      abort "MaHIS user import failed: #{e.message}"
    ensure
      User.current = nil if defined?(User)
      Location.current = nil if defined?(Location)
    end
  end
end
