# frozen_string_literal: true

require 'zlib'

# Rake task to dump metadata tables into a single gzipped SQL file
namespace :db do
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
    previous_foreign_key_checks = conn.select_value('SELECT @@FOREIGN_KEY_CHECKS')
    conn.execute('SET FOREIGN_KEY_CHECKS=0')

    indexed_words = 0
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

    indexed_words
  ensure
    conn.execute("SET FOREIGN_KEY_CHECKS=#{previous_foreign_key_checks || 1}") if defined?(conn) && conn
  end

  def write_concept_word_metadata!(file)
    conn = ActiveRecord::Base.connection

    Zlib::GzipWriter.open(file) do |gz|
      gz.write "-- MaHIS concept_word metadata generated #{Time.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}\n"
      gz.write "SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS;\n"
      gz.write "SET @OLD_SQL_MODE=@@SQL_MODE;\n"
      gz.write "SET FOREIGN_KEY_CHECKS=0;\n"
      gz.write "SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO';\n"
      gz.write "DELETE FROM `concept_word`;\n"
      gz.write "ALTER TABLE `concept_word` AUTO_INCREMENT=1;\n"

      rows = []
      conn.select_all(<<~SQL).each do |row|
        SELECT concept_id, word, locale, concept_name_id, weight
        FROM concept_word
        ORDER BY concept_word_id
      SQL
        rows << [
          row['concept_id'].to_i,
          conn.quote(row['word'].to_s),
          conn.quote(row['locale'].to_s),
          row['concept_name_id'].to_i,
          row['weight'].to_f
        ]

        next if rows.size < 1_000

        gz.write "INSERT INTO `concept_word` (`concept_id`,`word`,`locale`,`concept_name_id`,`weight`) VALUES\n"
        gz.write rows.map { |value| "(#{value.join(',')})" }.join(",\n")
        gz.write ";\n"
        rows.clear
      end

      if rows.any?
        gz.write "INSERT INTO `concept_word` (`concept_id`,`word`,`locale`,`concept_name_id`,`weight`) VALUES\n"
        gz.write rows.map { |value| "(#{value.join(',')})" }.join(",\n")
        gz.write ";\n"
      end

      gz.write "SET SQL_MODE=@OLD_SQL_MODE;\n"
      gz.write "SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS;\n"
    end
  end

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
    system("mysqldump -h #{db_host} -u#{db_user} -p#{db_pass} --no-data --routines --triggers #{db_name} | gzip > #{file}")

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

  desc 'Rebuild and dump concept name search index metadata into a gzipped SQL file'
  task dump_concept_word_metadata: :environment do
    output_dir = Rails.root.join('db/data')
    FileUtils.mkdir_p(output_dir)
    file = output_dir.join('z_concept_word.sql.gz')

    puts '🔎 Rebuilding concept name search index...'
    indexed_words = rebuild_concept_word_index!
    puts "✅ Rebuilt concept_word with #{indexed_words} rows"

    puts "💾 Dumping concept_word metadata into #{file} (gzipped)..."
    write_concept_word_metadata!(file)

    puts "\n✅ Concept search metadata dumped and gzipped to #{file}"
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
    Rake::Task['db:dump_concept_word_metadata'].invoke
    Rake::Task['db:dump_program_metadata'].invoke
  end
end
