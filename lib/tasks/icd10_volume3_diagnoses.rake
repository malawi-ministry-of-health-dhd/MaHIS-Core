# frozen_string_literal: true
#
# Usage:
#   SOURCE_PATH=/path/to/icd10-volume3-index.json rails icd10_volume3:generate_concepts_json
#   rails icd10_volume3:import_diagnoses
#
# Optional:
#   OUTPUT_PATH=/path/to/icd10-volume3-diagnosis-concepts.json rails icd10_volume3:generate_concepts_json
#   SOURCE_PATH=/path/to/icd10-volume3-diagnosis-concepts.json rails icd10_volume3:import_diagnoses
#   LIMIT=100 rails icd10_volume3:import_diagnoses
#   BATCH_SIZE=1000 rails icd10_volume3:import_diagnoses
#   DRY_RUN=true rails icd10_volume3:import_diagnoses
#
# Example:
#   DRY_RUN=true LIMIT=100 rails icd10_volume3:import_diagnoses
#
# Notes:
#   - Imports cleaned diagnosis concept names from the concept-ready ICD-10 Volume 3 JSON.
#   - Does not create ICD-10 codes or concept maps.
#   - Creates/updates the concept set: "ICD-10 Volume 3 Diagnosis".
#   - The raw ICD-10 Volume 3 index JSON is not kept in this repository.
#
# Source URLs:
#   WHO ICD-10 Volume 3 PDF:
#   https://doc.ukdataservice.ac.uk/doc/8763/mrdoc/pdf/icd-10_international_statistical_classification_of_diseases_and_related_health_problems-v3-eng.pdf
#
#   NHS ICD-10 Volume 3 browser:
#   https://classbrowser.nhs.uk/ICD-10-5TH-Edition/vol3/KRA_H.html
#
#   NHS site license:
#   https://classbrowser.nhs.uk/license.html
#
#   WHO ICD-11 implementation FAQ:
#   https://www.who.int/standards/classifications/frequently-asked-questions/icd-11-implementation

require 'json'
require 'fileutils'
require 'pathname'
require 'securerandom'
require 'set'
require 'time'

namespace :icd10_volume3 do
  desc 'Generate a concept-ready ICD-10 Volume 3 diagnosis JSON file for OpenMRS import'
  task generate_concepts_json: :environment do
    source_path = ENV['SOURCE_PATH'].to_s.strip
    raise 'SOURCE_PATH is required because the raw ICD-10 Volume 3 index JSON is not stored in this repository.' if source_path.empty?

    Icd10Volume3ConceptJsonGenerator.new(
      source_path: source_path,
      output_path: ENV.fetch('OUTPUT_PATH', Rails.root.join('db/data/icd10/icd10-volume3-diagnosis-concepts.json').to_s),
      limit: ENV['LIMIT']
    ).generate!
  end

  desc 'Create/update the ICD-10 Volume 3 Diagnosis concept set from db/data/icd10/icd10-volume3-diagnosis-concepts.json'
  task import_diagnoses: :environment do
    Icd10Volume3DiagnosisImporter.new(
      path: ENV.fetch('SOURCE_PATH', Icd10Volume3DiagnosisImporter.default_source_path.to_s),
      limit: ENV['LIMIT'],
      batch_size: ENV.fetch('BATCH_SIZE', 500).to_i,
      dry_run: ActiveModel::Type::Boolean.new.cast(ENV['DRY_RUN'])
    ).import!
  end
end

class Icd10Volume3ConceptJsonGenerator
  SOURCE_LABEL = 'ICD-10 Volume 3 Alphabetical Index'
  MAX_CONCEPT_NAME_LENGTH = 255
  LEAD_FIRST_TERMS = Set.new([
    'apgar',
    'iq',
    'karyotype',
    'trisomy',
    'weight'
  ]).freeze
  CLINICAL_NAME_OVERRIDES = {
    "Down's disease or syndrome" => 'Down syndrome',
    "Langdon Down's syndrome" => 'Down syndrome',
    "Down's syndrome translocation" => 'Translocation Down syndrome',
    "In Down's syndrome keratoconus" => 'Keratoconus in Down syndrome',
    'Type 2 diabetes' => 'Type 2 diabetes mellitus'
  }.freeze

  def initialize(source_path:, output_path:, limit:)
    @source_path = Pathname.new(source_path)
    @output_path = Pathname.new(output_path)
    @limit = limit.to_i.positive? ? limit.to_i : nil
  end

  def generate!
    payload = JSON.parse(File.read(@source_path))
    source_terms = Array(payload['terms'])
    source_terms = source_terms.first(@limit) if @limit

    stats = {
      total_source_entries_read: source_terms.length,
      skipped_cross_reference_entries: 0,
      skipped_navigation_entries: 0,
      skipped_non_diagnosis_entries: 0,
      skipped_long_names: 0,
      duplicate_names_removed: 0,
      entries_missing_code: 0
    }

    terms_by_name = {}

    source_terms.each do |term|
      stats[:entries_missing_code] += 1 if blank?(term_code(term))

      if cross_reference_only?(term)
        stats[:skipped_cross_reference_entries] += 1
        next
      end

      if navigation_entry?(term)
        stats[:skipped_navigation_entries] += 1
        next
      end

      code = term_code(term)
      next if blank?(code)

      name = concept_name(term)
      next if blank?(name)

      if non_diagnosis_concept?(term, name)
        stats[:skipped_non_diagnosis_entries] += 1
        next
      end

      if name.length > MAX_CONCEPT_NAME_LENGTH
        stats[:skipped_long_names] += 1
        next
      end

      if terms_by_name.key?(name)
        stats[:duplicate_names_removed] += 1
        next
      end

      terms_by_name[name] = {
        'name' => name,
        'code' => code,
        'sourceName' => source_name(term)
      }
    end

    terms = terms_by_name.values.sort_by { |term| term['name'].downcase }
    output = {
      'metadata' => {
        'source' => SOURCE_LABEL,
        'generatedAt' => Time.now.utc.iso8601,
        'termCount' => terms.length
      },
      'terms' => terms
    }

    FileUtils.mkdir_p(@output_path.dirname)
    File.write(@output_path, "#{JSON.pretty_generate(output)}\n")

    puts "ICD-10 Volume 3 source: #{@source_path}"
    puts "Concept-ready output: #{@output_path}"
    puts "Total source entries read: #{stats[:total_source_entries_read]}"
    puts "Total concepts generated: #{terms.length}"
    puts "Skipped cross-reference entries: #{stats[:skipped_cross_reference_entries]}"
    puts "Skipped navigation entries: #{stats[:skipped_navigation_entries]}"
    puts "Skipped non-diagnosis entries: #{stats[:skipped_non_diagnosis_entries]}"
    puts "Skipped long names: #{stats[:skipped_long_names]}"
    puts "Duplicate names removed: #{stats[:duplicate_names_removed]}"
    puts "Entries missing code: #{stats[:entries_missing_code]}"
  end

  private

  def source_name(term)
    normalize_spaces(term['sourceName'] || term['name'])
  end

  def term_code(term)
    code = term['code'].to_s.strip
    return code unless blank?(code)

    Array(term['codes']).map { |item| item.to_s.strip }.reject { |item| blank?(item) }.join(' + ')
  end

  def concept_name(term)
    lead = preferred_lead_name(term['leadTerm'])
    return nil if blank?(lead)

    modifiers = Array(term['modifiers'])
                .map { |modifier| clean_name_component(modifier) }
                .reject { |modifier| blank?(modifier) || navigation_text?(modifier) }

    raw_name = if modifiers.empty?
                 lead
               elsif lead_first_name?(lead)
                 "#{lead} #{modifiers.join(' ')}"
               else
                 [modifiers.first, lead_as_suffix(lead), *modifiers.drop(1)].join(' ')
               end

    normalize_concept_name(raw_name)
  end

  def preferred_lead_name(lead_term)
    canonical_lead_name(clean_name_component(lead_term).split(',').first.to_s.strip)
  end

  def lead_first_name?(lead)
    LEAD_FIRST_TERMS.include?(lead_key(lead))
  end

  def lead_as_suffix(lead)
    value = lead.to_s.strip
    return value if value.empty?

    "#{value[0].downcase}#{value[1..]}"
  end

  def canonical_lead_name(lead)
    return 'IQ' if lead_key(lead) == 'iq'

    lead
  end

  def lead_key(lead)
    lead.to_s.downcase.delete('.')
  end

  def clean_name_component(value)
    normalize_spaces(
      value.to_s
           .gsub(/\([^)]*\)/, ' ')
           .gsub(/\bNEC\b/i, ' ')
    )
  end

  def normalize_concept_name(value)
    normalized = normalize_spaces(value)
    return normalized if normalized.empty?

    name = "#{normalized[0].upcase}#{normalized[1..]}"
    CLINICAL_NAME_OVERRIDES.fetch(name, name)
  end

  def normalize_spaces(value)
    value.to_s.gsub(/\s+/, ' ').strip
  end

  def cross_reference_only?(term)
    Array(term['crossReferences']).any? && blank?(term_code(term))
  end

  def navigation_entry?(term)
    texts = [term['name'], term['leadTerm'], *Array(term['modifiers'])].map { |value| normalize_spaces(value).downcase }
    texts.any? { |text| navigation_text?(text) }
  end

  def navigation_text?(text)
    value = normalize_spaces(text).downcase
    value.empty? ||
      value == 'continued' ||
      value == 'for' ||
      value.start_with?('see ') ||
      value.include?(' see ') ||
      value.include?('fetus or newborn') ||
      value.include?('affecting fetus or newborn')
  end

  def non_diagnosis_concept?(term, name)
    source = source_name(term)
    code = term_code(term)
    joined_text = "#{name} #{source}"

    code.match?(/\A[ZVWXY]/) ||
      helper_chapter_source?(source) ||
      empty_grouping_name?(name) ||
      modifier_only_name?(name) ||
      administrative_concept?(name, source) ||
      observation_concept?(name, source) ||
      index_or_encounter_helper?(joined_text, source)
  end

  def helper_chapter_source?(source)
    source.match?(/\A(?:Conditions arising in the perinatal period|External causes of morbidity and mortality|Factors influencing health status and contact with health services)\b/i)
  end

  def empty_grouping_name?(name)
    name.match?(/\A(?:abdomen|abnormality|accident|disease|disorder|condition)\z/i)
  end

  def modifier_only_name?(name)
    name.match?(/\A(?:acute|chronic|specified|unspecified|bilateral|left|right|upper|lower|for|with|without|mother|fetus|newborn|nec|nos)\z/i)
  end

  def administrative_concept?(name, source)
    name.match?(/\A(?:History of|Contact with|Observation|Follow[- ]up|Screening|Counselling|Counseling|Admission|Aftercare|Rehabilitation)\b/i) ||
      source.match?(/\A(?:History|Contact|Observation|Follow[- ]up|Screening|Counselling|Counseling|Admission|Aftercare|Rehabilitation)\b/i) ||
      name.match?(/\AExposure(?:\z| to\b)/i)
  end

  def observation_concept?(name, source)
    source.match?(/\AApgar\b/i) ||
      source.match?(/\AWeight - \d/i) ||
      source.match?(/\AAbnormal, abnormality, abnormalities - specimen\b/i) ||
      source.match?(/\ATest\(s\)\b/i) ||
      source.match?(/\A(?:HIV|Human - immunodeficiency virus).*\b(?:laboratory evidence|nonconclusive test)\b/i) ||
      source.match?(/\AFalse - positive serological test\b/i) ||
      source.match?(/\AReaction - tuberculin skin test, abnormal\b/i) ||
      source.match?(/\AAbnormal, abnormality, abnormalities - (?:caloric test|kidney function test|renal function test|pulmonary - test results|Mantoux test)\b/i) ||
      name.match?(/\A(?:HIV test|Nonconclusive test|Laboratory evidence|Test, human immunodeficiency virus|Wassermann test|Mantoux, abnormal result test|Tuberculin, abnormal result test|Positive serological test)\b/i)
  end

  def index_or_encounter_helper?(joined_text, source)
    joined_text.match?(/\baffecting fetus\b/i) ||
      joined_text.match?(/\b(?:affecting management|management affected)\b/i) ||
      joined_text.match?(/\bmaternal care\b/i) ||
      joined_text.match?(/\bcesarean delivery\b|\bDelivery \(single\) - cesarean\b/i) ||
      source.match?(/\bto facilitate delivery\b/i) ||
      source.match?(/\A(?:Cranioclasis|Craniotomy|Embryotomy|Destruction, destructive - live fetus)/i) ||
      source.match?(/\AAbortion .* - fetus\b/i)
  end

  def blank?(value)
    value.nil? || value.to_s.strip.empty?
  end
end

class Icd10Volume3DiagnosisImporter
  SET_NAME = 'ICD-10 Volume 3 Diagnosis'
  MAX_CONCEPT_NAME_LENGTH = 255

  def self.default_source_path
    Rails.root.join('db/data/icd10/icd10-volume3-diagnosis-concepts.json')
  end

  def initialize(path:, limit:, batch_size:, dry_run:)
    @path = Pathname.new(path)
    @limit = limit.to_i.positive? ? limit.to_i : nil
    @batch_size = batch_size.positive? ? batch_size : 500
    @dry_run = dry_run
  end

  def import!
    names = diagnosis_names
    skipped_names = overlong_names(names)
    names -= skipped_names

    set_concept = find_set_concept
    existing_by_name = existing_concepts_by_name(names)
    missing_names = names.reject { |name| existing_by_name.key?(name) }

    puts "ICD-10 Volume 3 source: #{@path}"
    puts "Unique cleaned diagnosis names: #{names.length}"
    puts "Skipped overlong names: #{skipped_names.length}"
    puts "Existing concepts: #{existing_by_name.length}"
    puts "Concepts to create: #{missing_names.length}"
    puts "Concept set: #{SET_NAME}#{set_concept ? " (concept_id: #{set_concept.concept_id})" : ' (will be created)'}"

    if @dry_run
      existing_member_ids = set_concept ? concept_set_member_ids(set_concept.concept_id, existing_by_name.values.map(&:concept_id)) : []
      puts "Existing set memberships among current concepts: #{existing_member_ids.length}"
      write_skipped_names!(skipped_names)
      puts 'Dry run only; no concepts or memberships were written.'
      return
    end

    write_skipped_names!(skipped_names)

    set_concept ||= create_set_concept!
    concepts_by_name = existing_by_name

    missing_names.each_slice(@batch_size).with_index(1) do |slice, index|
      ActiveRecord::Base.transaction do
        slice.each do |name|
          concepts_by_name[name] = create_diagnosis_concept!(name)
        end
      end

      puts "Created concepts batch #{index}: #{[index * @batch_size, missing_names.length].min}/#{missing_names.length}"
    end

    member_concepts = names.map { |name| concepts_by_name.fetch(name) }
    existing_member_ids = concept_set_member_ids(set_concept.concept_id, member_concepts.map(&:concept_id))
    missing_members = member_concepts.reject { |concept| existing_member_ids.include?(concept.concept_id) }

    missing_members.each_slice(@batch_size).with_index(1) do |slice, index|
      ActiveRecord::Base.transaction do
        slice.each_with_index do |concept, offset|
          create_membership!(set_concept.concept_id, concept.concept_id, (index - 1) * @batch_size + offset + 1)
        end
      end

      puts "Linked concept set batch #{index}: #{[index * @batch_size, missing_members.length].min}/#{missing_members.length}"
    end

    total_members = ConceptSet.where(concept_set: set_concept.concept_id).distinct.count(:concept_id)
    puts "Imported '#{SET_NAME}' with #{total_members} members"
    puts 'No ICD-10 codes or concept maps were created; only cleaned diagnosis concept names were imported.'
  end

  private

  def diagnosis_names
    payload = JSON.parse(File.read(@path))

    names = Array(payload['terms'])
            .map { |term| diagnosis_name_from_term(term) }
            .reject(&:blank?)
            .uniq

    @limit ? names.first(@limit) : names
  end

  def diagnosis_name_from_term(term)
    return normalize_name(term['name']) if term.key?('sourceName') && term['name'].present?

    lead_term = clean_index_text(term['leadTerm'])
    modifiers = Array(term['modifiers'])
                .map { |modifier| clean_index_text(modifier) }
                .reject(&:blank?)

    return nil if lead_term.blank?
    return normalize_name(preferred_lead_name(lead_term)) if modifiers.empty?

    meaningful_modifiers = modifiers.reject { |modifier| skip_modifier?(modifier) }
    return normalize_name(preferred_lead_name(lead_term)) if meaningful_modifiers.empty?

    build_readable_diagnosis_name(lead_term, meaningful_modifiers)
  end

  def clean_index_text(value)
    value.to_s
         .gsub(/\([^)]*\)/, '')
         .gsub(/\bNEC\b/i, '')
         .gsub(/\s+/, ' ')
         .strip
  end

  def skip_modifier?(modifier)
    text = modifier.downcase.strip

    text.blank? ||
      text == 'continued' ||
      text == 'for' ||
      text.start_with?('see ') ||
      text.include?(' see ') ||
      text.include?('fetus or newborn') ||
      text.include?('affecting fetus or newborn')
  end

  def build_readable_diagnosis_name(lead_term, modifiers)
    lead = preferred_lead_name(lead_term)

    name = "#{modifiers.join(' ')} #{lead}"
    normalize_name(title_case_first_word(name))
  end

  def preferred_lead_name(lead_term)
    lead_term.to_s.split(',').first.to_s.strip
  end

  def title_case_first_word(value)
    value = value.to_s.strip
    return value if value.blank?

    value[0].upcase + value[1..]
  end

  def normalize_name(value)
    value.to_s.strip.gsub(/\s+/, ' ')
  end

  def overlong_names(names)
    names.select { |name| name.length > MAX_CONCEPT_NAME_LENGTH }
  end

  def write_skipped_names!(names)
    return if names.empty?

    path = Rails.root.join('log/icd10_volume3_skipped_names.log')
    File.write(path, names.join("\n"))
    puts "Skipped name report: #{path}"
  end

  def find_set_concept
    Concept.find_by_name(SET_NAME)
  end

  def create_set_concept!
    datatype = ConceptDatatype.find_by(name: 'N/A') || ConceptDatatype.find_by(name: 'Coded')
    klass = ConceptClass.find_by(name: 'ConvSet') || ConceptClass.find_by(name: 'Conv') || ConceptClass.find_by(name: 'Question')
    raise 'Missing concept datatype/class for ICD-10 Volume 3 concept set' unless datatype && klass

    ActiveRecord::Base.transaction do
      concept = Concept.create!(
        datatype_id: datatype.concept_datatype_id,
        class_id: klass.concept_class_id,
        creator: creator_id,
        date_created: Time.zone.now,
        retired: 0,
        is_set: 1,
        uuid: SecureRandom.uuid
      )

      create_concept_name!(concept.concept_id, SET_NAME)
      concept
    end
  end

  def create_diagnosis_concept!(name)
    datatype = ConceptDatatype.find_by(name: 'N/A') || ConceptDatatype.find_by(name: 'Coded')
    klass = ConceptClass.find_by(name: 'Diagnosis') || ConceptClass.find_by(name: 'Misc')
    raise "Missing concept datatype/class for ICD-10 Volume 3 diagnosis '#{name}'" unless datatype && klass

    concept = Concept.create!(
      datatype_id: datatype.concept_datatype_id,
      class_id: klass.concept_class_id,
      creator: creator_id,
      date_created: Time.zone.now,
      retired: 0,
      is_set: 0,
      uuid: SecureRandom.uuid
    )

    create_concept_name!(concept.concept_id, name)
    concept
  end

  def create_concept_name!(concept_id, name)
    ConceptName.create!(
      concept_id: concept_id,
      name: name,
      locale: 'en',
      locale_preferred: 1,
      concept_name_type: 'FULLY_SPECIFIED',
      creator: creator_id,
      date_created: Time.zone.now,
      voided: 0,
      uuid: SecureRandom.uuid
    )
  end

  def create_membership!(set_concept_id, member_concept_id, sort_weight)
    ConceptSet.create!(
      concept_set: set_concept_id,
      concept_id: member_concept_id,
      sort_weight: sort_weight,
      creator: creator_id,
      date_created: Time.zone.now,
      uuid: SecureRandom.uuid
    )
  end

  def existing_concepts_by_name(names)
    names.each_slice(1000).each_with_object({}) do |slice, concepts|
      ConceptName
        .where(name: slice, voided: 0)
        .order(Arel.sql("concept_name_type = 'FULLY_SPECIFIED' DESC"))
        .includes(:concept)
        .each do |concept_name|
          concepts[concept_name.name] ||= concept_name.concept
        end
    end
  end

  def concept_set_member_ids(set_concept_id, member_ids)
    member_ids.each_slice(1000).each_with_object(Set.new) do |slice, ids|
      ConceptSet.where(concept_set: set_concept_id, concept_id: slice).pluck(:concept_id).each { |id| ids << id }
    end
  end

  def creator_id
    @creator_id ||= User.unscoped.order(:user_id).pick(:user_id) || 1
  end
end
