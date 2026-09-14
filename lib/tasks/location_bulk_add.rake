# frozen_string_literal: true

require 'shellwords'

namespace :locations do
  def truthy_env?(value)
    %w[1 true yes y].include?(value.to_s.strip.downcase)
  end

  def run_location_bulk_add(mode)
    script = Rails.root.join('bin', 'location_bulk_add.rb').to_s
    input = ENV['INPUT'].presence || Rails.root.join('data', 'locations_to_add.csv').to_s
    manifest = ENV['MANIFEST'].presence
    creator_id = (ENV['CREATOR_ID'].presence || '1').to_i
    dry_run = truthy_env?(ENV['DRY_RUN'])

    command = [script, mode, '--creator', creator_id.to_s]
    command += ['--input', input] if mode == 'apply'
    command += ['--manifest', manifest] if mode == 'revert' && manifest
    command << '--dry-run' if dry_run

    puts "Running #{mode} command: #{Shellwords.join(command)}"
    success = system(*command)
    raise "locations:bulk_add:#{mode} failed" unless success
  end

  namespace :bulk_add do
    desc 'Apply location CSV import. ENV: INPUT=path CREATOR_ID=1 DRY_RUN=true|false'
    task apply: :environment do
      run_location_bulk_add('apply')
    end

    desc 'Revert location import using latest or MANIFEST=path. ENV: CREATOR_ID=1 DRY_RUN=true|false'
    task revert: :environment do
      run_location_bulk_add('revert')
    end
  end
end