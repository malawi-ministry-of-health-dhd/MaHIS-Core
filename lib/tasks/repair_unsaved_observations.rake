# frozen_string_literal: true
#
# Usage:
#   bin/rails couchdb:repair_unsaved_observations
#   DRY_RUN=false bin/rails couchdb:repair_unsaved_observations
#   DRY_RUN=false PATIENT_ID=P170000000022 bin/rails couchdb:repair_unsaved_observations
#   LIMIT=100 bin/rails couchdb:repair_unsaved_observations
#   DRY_RUN=false BATCH_SIZE=500 bin/rails couchdb:repair_unsaved_observations

require 'json'
require 'rest-client'
require 'yaml'
require Rails.root.join('lib', 'couchdb_url').to_s

class CouchdbUnsavedObservationRepairTask
  CONFIG = YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')))
  COUCHDB_URL = CONFIG['COUCHDB_URL']
  PATIENTS_DB = 'patients_records'
  DEFAULT_BATCH_SIZE = 200

  def initialize(env = ENV)
    @dry_run = env.fetch('DRY_RUN', 'true').to_s.downcase != 'false'
    @batch_size = positive_integer(env['BATCH_SIZE'], DEFAULT_BATCH_SIZE)
    @limit = positive_integer(env['LIMIT'], nil)
    @patient_id = env['PATIENT_ID'].presence || env['ID'].presence
    @service = SavePatientRecordService.new
    @processed = 0
    @repaired = 0
    @skipped = 0
    @failed = 0
  end

  def run
    raise 'COUCHDB_URL is not configured in config/application.yml' if COUCHDB_URL.blank?

    puts "\n===== CouchDB Unsaved Observation Repair ====="
    puts "Database: #{PATIENTS_DB}"
    puts "Mode: #{@dry_run ? 'dry run' : 'write'}"
    puts "Patient: #{@patient_id}" if @patient_id.present?
    puts "Limit: #{@limit}" if @limit.present?
    puts

    @patient_id.present? ? process_single_patient : process_all_patients

    puts "\n===== Repair Summary ====="
    puts "Checked: #{@processed}"
    puts "Repaired: #{@repaired}"
    puts "Skipped: #{@skipped}"
    puts "Failed: #{@failed}"
    puts @dry_run ? "\nDry run only. Re-run with DRY_RUN=false to save." : "\nDone."
  end

  private

  def process_single_patient
    doc = fetch_doc(@patient_id)
    unless doc
      puts "Patient record not found in CouchDB: #{@patient_id}"
      return
    end

    process_doc(doc)
  end

  def process_all_patients
    bookmark = nil

    loop do
      docs, bookmark = find_unsaved_observation_docs(bookmark)
      break if docs.empty?

      docs.each do |doc|
        break if @limit.present? && @processed >= @limit

        process_doc(doc)
      end

      break if @limit.present? && @processed >= @limit
      break if bookmark.blank?
    end
  end

  def process_doc(doc)
    current_doc = fetch_doc(doc['_id']) || doc
    unsaved_groups = unsaved_observation_groups(current_doc)
    @processed += 1

    if unsaved_groups.empty?
      @skipped += 1
      return
    end

    description = "#{current_doc['_id']} unsaved_groups=#{unsaved_groups.length} encounter_types=#{encounter_types(unsaved_groups).join(',')}"

    if @dry_run
      puts "Would repair #{description}"
      @skipped += 1
      return
    end

    with_record_context(current_doc) do
      repaired_record = @service.create_patient_record(current_doc.with_indifferent_access)
      unless repaired_record.respond_to?(:with_indifferent_access)
        raise "Patient record repair did not return a payload: #{repaired_record.inspect}"
      end

      remaining_unsaved = unsaved_observation_groups(repaired_record)
      operation_errors = repaired_record.with_indifferent_access[:operation_errors]

      if remaining_unsaved.empty? && operation_errors.blank?
        @repaired += 1
        puts "Repaired #{current_doc['_id']}"
      else
        @failed += 1
        puts "Partially repaired #{current_doc['_id']}: remaining_unsaved=#{remaining_unsaved.length} errors=#{operation_errors.inspect}"
      end
    end
  rescue StandardError => e
    @failed += 1
    puts "Failed #{doc && doc['_id']}: #{e.class}: #{e.message}"
  end

  def find_unsaved_observation_docs(bookmark = nil)
    query = {
      selector: {
        observations: {
          '$elemMatch' => {
            status: 'unsaved'
          }
        }
      },
      limit: @batch_size
    }
    query[:bookmark] = bookmark if bookmark.present?

    response = RestClient.post(
      couchdb_url(PATIENTS_DB, '_find'),
      query.to_json,
      { content_type: :json, accept: :json }
    )

    parsed = JSON.parse(response.body)
    [parsed.fetch('docs', []), parsed['bookmark']]
  end

  def fetch_doc(doc_id)
    response = RestClient.get(couchdb_url(PATIENTS_DB, URI.encode_www_form_component(doc_id.to_s)))
    JSON.parse(response.body)
  rescue RestClient::NotFound
    nil
  end

  def unsaved_observation_groups(record)
    Array(record_value(record, :observations)).select do |group|
      record_value(group, :status).to_s == 'unsaved' && Array(record_value(group, :obs)).any?
    end
  end

  def encounter_types(groups)
    groups.map { |group| record_value(group, :encounter_type) }.compact.uniq
  end

  def with_record_context(record)
    previous_user = User.current
    previous_location = Location.current

    location_id = record_value(record, :location_id)
    Location.current = Location.unscoped.find_by(location_id: location_id) || Location.current_health_center

    provider_id = record_value(record, :provider_id)
    User.current = User.unscoped.find_by(user_id: provider_id) if provider_id.present?

    yield
  ensure
    User.current = previous_user
    Location.current = previous_location
  end

  def record_value(container, key)
    return nil if container.nil? || !container.respond_to?(:[])

    container[key] || container[key.to_s]
  rescue TypeError
    nil
  end

  def couchdb_url(*segments)
    CouchdbUrl.join(COUCHDB_URL, *segments)
  end

  def positive_integer(value, fallback)
    return fallback if value.blank?

    parsed = value.to_i
    parsed.positive? ? parsed : fallback
  end
end

namespace :couchdb do
  desc 'Repair patient CouchDB records that still contain unsaved observations, regardless of processed_by_listener'
  task repair_unsaved_observations: :environment do
    CouchdbUnsavedObservationRepairTask.new.run
  end
end
