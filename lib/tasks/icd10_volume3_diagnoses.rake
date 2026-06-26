# frozen_string_literal: true

require 'json'
require 'pathname'
require 'securerandom'
require 'set'

namespace :icd10_volume3 do
  desc 'Create/update the ICD-10 Volume 3 Diagnosis concept set from db/data/icd10/icd10-volume3-index.json'
  task import_diagnoses: :environment do
    Icd10Volume3DiagnosisImporter.new(
      path: ENV.fetch('SOURCE_PATH', Rails.root.join('db/data/icd10/icd10-volume3-index.json').to_s),
      limit: ENV['LIMIT'],
      batch_size: ENV.fetch('BATCH_SIZE', 500).to_i,
      dry_run: ActiveModel::Type::Boolean.new.cast(ENV['DRY_RUN'])
    ).import!
  end
end

class Icd10Volume3DiagnosisImporter
  SET_NAME = 'ICD-10 Volume 3 Diagnosis'
  MAX_CONCEPT_NAME_LENGTH = 255

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
    puts "Unique diagnosis names: #{names.length}"
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
    puts 'No ICD-10 codes or concept maps were created; only diagnosis concept names were imported.'
  end

  private

  def diagnosis_names
    payload = JSON.parse(File.read(@path))
    names = Array(payload['terms'])
            .map { |term| normalize_name(term['name']) }
            .reject(&:blank?)
            .uniq

    @limit ? names.first(@limit) : names
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
