# frozen_string_literal: true

# Rake task to dump metadata tables into a single gzipped SQL file
namespace :db do
  desc 'Dump entire database skeleton (schema + routines + triggers) into a gzipped SQL file'
  task dump_skeleton_metadata: :environment do
    db_config = Rails.configuration.database_configuration[Rails.env]
    db_name   = db_config['database']
    db_user   = db_config['username']
    db_pass   = db_config['password']
    db_host   = db_config['host'] || '127.0.0.1'

    output_dir = Rails.root.join('db')
    FileUtils.mkdir_p(output_dir)
    file = output_dir.join('mahis_skeleton.sql.gz')

    puts "💾 Dumping full database skeleton for #{db_name} into #{file} (gzipped)..."

    # mysqldump with --no-data, --routines, --triggers, piped to gzip
    system("mysqldump -h #{db_host} -u#{db_user} -p#{db_pass} --no-data --routines --triggers --set-gtid-purged=OFF #{db_name} | gzip > #{file}")

    puts "\n✅ Database skeleton dumped and gzipped to #{file}"
  end

  desc 'Dump other metadata tables into a gzipped SQL file'
  task dump_other_metadata: :environment do
    db_config = Rails.configuration.database_configuration[Rails.env]
    db_name   = db_config['database']
    db_user   = db_config['username']
    db_pass   = db_config['password']
    db_host   = db_config['host'] || '127.0.0.1'

    tables = %w[
      encounter_type program order_type patient_identifier_type drug person_attribute_type relationship_type
    ]

    output_dir = Rails.root.join('db/data')
    FileUtils.mkdir_p(output_dir)
    file = output_dir.join('other_metadata.sql.gz')

    puts "💾 Dumping all metadata tables into #{file} (gzipped)..."

    # Join tables into a single space-separated string
    tables_list = tables.join(' ')

    # Run mysqldump and pipe to gzip directly
    system("mysqldump -h #{db_host} -u#{db_user} -p#{db_pass} #{db_name} #{tables_list} | gzip > #{file}")

    puts "\n✅ All metadata tables dumped and gzipped to #{file}"
  end

  desc 'Dump concept metadata tables into a gzipped SQL file'
  task dump_concept_metadata: :environment do
    db_config = Rails.configuration.database_configuration[Rails.env]
    db_name   = db_config['database']
    db_user   = db_config['username']
    db_pass   = db_config['password']
    db_host   = db_config['host'] || '127.0.0.1'

    tables = %w[
      concept concept_name concept_set concept_source concept_map_type concept_map concept_attribute_type concept_attribute
    ]

    output_dir = Rails.root.join('db/data')
    FileUtils.mkdir_p(output_dir)
    file = output_dir.join('icd_11_concepts_metadata.sql.gz')

    puts "💾 Dumping all metadata tables into #{file} (gzipped)..."

    # Join tables into a single space-separated string
    tables_list = tables.join(' ')

    # Run mysqldump and pipe to gzip directly
    system("mysqldump -h #{db_host} -u#{db_user} -p#{db_pass} #{db_name} #{tables_list} | gzip > #{file}")

    puts "\n✅ All metadata tables dumped and gzipped to #{file}"
  end

  desc 'Dump program metadata tables into a gzipped SQL file'
  task dump_program_metadata: :environment do
    db_config = Rails.configuration.database_configuration[Rails.env]
    db_name   = db_config['database']
    db_user   = db_config['username']
    db_pass   = db_config['password']
    db_host   = db_config['host'] || '127.0.0.1'

    tables = %w[
      program program_workflow program_workflow_state
    ]

    output_dir = Rails.root.join('db/data')
    FileUtils.mkdir_p(output_dir)
    file = output_dir.join('program_export.sql.gz')

    puts "💾 Dumping all metadata tables into #{file} (gzipped)..."

    # Join tables into a single space-separated string
    tables_list = tables.join(' ')

    # Run mysqldump and pipe to gzip directly
    system("mysqldump -h #{db_host} -u#{db_user} -p#{db_pass} #{db_name} #{tables_list} | gzip > #{file}")

    puts "\n✅ All metadata tables dumped and gzipped to #{file}"
  end

  desc 'Dump all at once metadata tables into gzipped SQL files'
  task dump_all_metadata: :environment do
    Rake::Task['db:dump_skeleton_metadata'].invoke
    Rake::Task['db:dump_other_metadata'].invoke
    Rake::Task['db:dump_concept_metadata'].invoke
    Rake::Task['db:dump_program_metadata'].invoke
  end
end
