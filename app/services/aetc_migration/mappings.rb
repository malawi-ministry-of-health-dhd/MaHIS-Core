# frozen_string_literal: true

require 'csv'

module AetcMigration
  # Reads the mapping files (db/aetc_migration/mappings or AETC_MAPPINGS_DIR) and loads them into
  # lookup tables in the run's tracking schema, so the migration steps can join on them in SQL.
  #
  #   lookup_<name>            source_id -> target_id, action (map / skip / unmapped / not_used)
  #   lookup_location          scope 'default' (all tables) or 'clinical' (encounters and obs; adds
  #                            location.json clinical_overrides)
  #   lookup_concept_question  obs concept -> MaHIS concept, action, reviewed
  #   lookup_concept_rule      per obs concept and AETC value column: none / coded / text_to_coded / ...
  #   lookup_concept_answer    coded answer -> MaHIS concept (and the AETC name, kept if unmapped)
  #   lookup_concept_value     text value of a text_to_coded concept -> MaHIS concept
  #                            (value_map in concept.json plus filled rows of concept_unmapped_values.csv)
  #   lookup_specimen          orders.concept_id -> MaHIS concept
  class Mappings
    FILES = %w[concept.json concept_unmapped_values.csv decisions.json encounter_type.json location.json
               order_type.json patient_identifier_type.json person_address.json person_attribute_type.json
               relationship_type.json users.json value_normalization.json visit_type.json].freeze

    # lookup table => [mapping file, MaHIS table, MaHIS id column]
    SIMPLE = {
      'visit_type' => ['visit_type.json', 'visit_type', 'visit_type_id'],
      'encounter_type' => ['encounter_type.json', 'encounter_type', 'encounter_type_id'],
      'order_type' => ['order_type.json', 'order_type', 'order_type_id'],
      'identifier_type' => ['patient_identifier_type.json', 'patient_identifier_type', 'patient_identifier_type_id'],
      'attribute_type' => ['person_attribute_type.json', 'person_attribute_type', 'person_attribute_type_id'],
      'relationship_type' => ['relationship_type.json', 'relationship_type', 'relationship_type_id']
    }.freeze

    # Lookup tables whose target_id must exist in MaHIS: table => [MaHIS table, id column, what]
    TARGETS = SIMPLE.to_h { |name, (_, table, column)| ["lookup_#{name}", [table, column, name.tr('_', ' ')]] }.merge(
      'lookup_location' => %w[location location_id location],
      'lookup_concept_question' => ['concept', 'concept_id', 'obs concept'],
      'lookup_concept_answer' => ['concept', 'concept_id', 'coded answer'],
      'lookup_concept_value' => ['concept', 'concept_id', 'text value'],
      'lookup_specimen' => %w[concept concept_id specimen]
    ).freeze

    def initialize(dir)
      @dir = Pathname(dir)
    end

    def missing_files
      FILES.reject { |f| @dir.join(f).file? }
    end

    def json(name)
      @json ||= {}
      @json[name] ||= JSON.parse(@dir.join(name).read(encoding: 'UTF-8'))
    rescue Errno::ENOENT
      raise Error, "Mapping file #{@dir.join(name)} is missing"
    rescue JSON::ParserError => e
      raise Error, "Mapping file #{name} is not valid JSON: #{e.message.lines.first.strip}"
    end

    # {lookup table => rows}; every row is a hash with the table's columns.
    def tables
      @tables ||= SIMPLE.to_h { |name, (file, _, _)| ["lookup_#{name}", simple_rows(json(file)['mappings'])] }.merge(
        'lookup_location' => location_rows,
        'lookup_concept_question' => question_rows,
        'lookup_concept_rule' => rule_rows,
        'lookup_concept_answer' => answer_rows,
        'lookup_concept_value' => value_rows,
        'lookup_specimen' => specimen_rows
      )
    end

    COLUMNS = {
      'lookup_location' => 'scope VARCHAR(10) NOT NULL, source_id BIGINT NOT NULL, target_id BIGINT NULL, ' \
                           'action VARCHAR(20) NOT NULL, PRIMARY KEY (scope, source_id)',
      'lookup_concept_question' => 'source_id BIGINT NOT NULL PRIMARY KEY, target_id BIGINT NULL, ' \
                                   'action VARCHAR(20) NOT NULL, reviewed TINYINT NOT NULL',
      'lookup_concept_rule' => 'source_id BIGINT NOT NULL, value_column VARCHAR(30) NOT NULL, rule VARCHAR(40) NOT NULL, ' \
                               'PRIMARY KEY (source_id, value_column)',
      'lookup_concept_answer' => 'source_id BIGINT NOT NULL PRIMARY KEY, target_id BIGINT NULL, ' \
                                 'action VARCHAR(20) NOT NULL, source_name VARCHAR(255) NULL',
      'lookup_concept_value' => 'source_id BIGINT NOT NULL, value_text VARCHAR(255) COLLATE utf8mb4_bin NOT NULL, ' \
                                'target_id BIGINT NOT NULL, origin VARCHAR(20) NOT NULL, PRIMARY KEY (source_id, value_text)',
      'lookup_specimen' => 'source_id BIGINT NOT NULL PRIMARY KEY, target_id BIGINT NOT NULL, origin VARCHAR(20) NOT NULL'
    }.freeze
    SIMPLE_COLUMNS = 'source_id BIGINT NOT NULL PRIMARY KEY, target_id BIGINT NULL, action VARCHAR(20) NOT NULL'

    # (Re)creates the lookup tables in the tracking schema. Returns {table => rows loaded}.
    def load_into(tracking, connection: ActiveRecord::Base.connection)
      tables.to_h do |table, rows|
        name = tracking.table_name(table)
        connection.execute("DROP TABLE IF EXISTS #{name}")
        connection.execute("CREATE TABLE #{name} (#{COLUMNS.fetch(table, SIMPLE_COLUMNS)}) CHARACTER SET utf8mb4")
        rows.each_slice(1000) do |slice|
          columns = slice.first.keys
          values = slice.map { |row| "(#{columns.map { |c| connection.quote(row[c]) }.join(', ')})" }
          connection.execute("INSERT INTO #{name} (#{columns.join(', ')}) VALUES #{values.join(', ')}")
        end
        [table, rows.size]
      end
    end

    def aetc_program_id
      json('encounter_type.json').dig('related_for_encounter_migration', 'mahis_program', 'program_id')
    end

    private

    def simple_rows(entries)
      entries.map { |m| { 'source_id' => m['source_id'], 'target_id' => m['target_id'], 'action' => m['action'] } }
    end

    def location_rows
      doc = json('location.json')
      default = simple_rows(doc['mappings'])
      overrides = simple_rows(doc.dig('clinical_overrides', 'mappings') || [])
      clinical = default.reject { |r| overrides.any? { |o| o['source_id'] == r['source_id'] } } + overrides
      default.map { |r| r.merge('scope' => 'default') } + clinical.map { |r| r.merge('scope' => 'clinical') }
    end

    def questions
      json('concept.json')['questions']
    end

    def question_rows
      questions.map do |q|
        { 'source_id' => q['source_id'], 'target_id' => q['target_id'], 'action' => q['action'],
          'reviewed' => q['reviewed'] ? 1 : 0 }
      end
    end

    def rule_rows
      questions.flat_map do |q|
        (q['conversions'] || {}).map { |column, c| { 'source_id' => q['source_id'], 'value_column' => column, 'rule' => c['rule'] } }
      end
    end

    def answer_rows
      json('concept.json')['answers'].map do |a|
        { 'source_id' => a['source_id'], 'target_id' => a['target_id'], 'action' => a['action'],
          'source_name' => a['source_name'] }
      end
    end

    # concept.json value maps first; the worksheet only adds values they don't cover.
    def value_rows
      rows = {}
      questions.each do |q|
        q.dig('conversions', 'value_text', 'value_map')&.each do |text, hit|
          next unless hit['target_id']

          rows[[q['source_id'], text.strip]] ||= { 'source_id' => q['source_id'], 'value_text' => text.strip,
                                                   'target_id' => hit['target_id'], 'origin' => 'concept.json' }
        end
      end
      worksheet_rows.each { |row| rows[[row['source_id'], row['value_text']]] ||= row }
      rows.values
    end

    def worksheet_rows
      path = @dir.join('concept_unmapped_values.csv')
      return [] unless path.file?

      CSV.read(path, headers: true, encoding: 'bom|utf-8').filter_map do |row|
        fields = row.fields
        next unless fields[2] == 'text_to_coded' && fields[5].to_s.strip.match?(/\A\d+\z/)

        { 'source_id' => fields[0].to_i, 'value_text' => fields[3].to_s.strip, 'target_id' => fields[5].strip.to_i,
          'origin' => 'worksheet' }
      end
    rescue CSV::MalformedCSVError => e
      raise Error, "concept_unmapped_values.csv could not be read: #{e.message}"
    end

    # Any mapped AETC concept can be a specimen; order_type.json adds specimens concept.json lacks.
    def specimen_rows
      rows = {}
      add = lambda do |source, target, origin|
        rows[source] = { 'source_id' => source, 'target_id' => target, 'origin' => origin } if target
      end
      json('concept.json')['answers'].each { |a| add.call(a['source_id'], a['target_id'], 'concept.json') }
      questions.each { |q| add.call(q['source_id'], q['target_id'], 'concept.json') }
      json('order_type.json').dig('specimen_concepts', 'mappings')&.each do |m|
        add.call(m['source_id'], m['target_id'], 'order_type.json')
      end
      rows.values
    end
  end
end
