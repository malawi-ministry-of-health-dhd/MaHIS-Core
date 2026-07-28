# frozen_string_literal: true

require 'csv'
require 'fileutils'
require 'json'

# Read-only diagnostic report for the patient sync safeguards that previously
# rejected unusually large source records. Count checks intentionally use
# unscoped rows so the results match the removed sync checks exactly.
class PatientSyncThresholdReport
  OBSERVATION_LIMIT = 50_000
  ORDER_LIMIT = 20_000
  DOCUMENT_LIMIT_BYTES = 7 * 1024 * 1024
  DEFAULT_BATCH_SIZE = 100
  DEFAULT_PROGRESS_EVERY = 100
  DOCUMENT_SCAN_MODES = %w[all candidates none].freeze

  def initialize(env = ENV)
    @patient_ids = parse_patient_ids(env['PATIENT_IDS'].presence || env['PATIENT_ID'].presence)
    @document_scan = env.fetch('DOCUMENT_SCAN', 'all').to_s.downcase
    @batch_size = positive_integer(env['BATCH_SIZE'], DEFAULT_BATCH_SIZE)
    @progress_every = positive_integer(env['PROGRESS_EVERY'], DEFAULT_PROGRESS_EVERY)
    @output_path = File.expand_path(
      env['OUTPUT'].presence || Rails.root.join('tmp', 'patient_sync_threshold_report.csv').to_s,
      Rails.root
    )
    @error_path = error_path_for(@output_path)

    validate_options!
  end

  def run
    print_header

    observation_overages = count_overages(
      Observation.unscoped,
      :person_id,
      OBSERVATION_LIMIT
    )
    order_overages = count_overages(
      Order.unscoped,
      :patient_id,
      ORDER_LIMIT
    )

    matches = initialize_count_matches(observation_overages, order_overages)
    build_errors = scan_documents(matches, observation_overages.keys | order_overages.keys)
    populate_all_counts(matches)
    write_report(matches)
    write_errors(build_errors)
    print_summary(matches, build_errors)
  end

  private

  def parse_patient_ids(value)
    return [] if value.blank?

    value.to_s.split(',').map(&:strip).reject(&:blank?).map do |patient_id|
      Integer(patient_id, 10)
    rescue ArgumentError
      raise ArgumentError, "Invalid patient id: #{patient_id.inspect}"
    end.uniq
  end

  def positive_integer(value, fallback)
    parsed = value.to_i
    parsed.positive? ? parsed : fallback
  end

  def validate_options!
    unless DOCUMENT_SCAN_MODES.include?(@document_scan)
      raise ArgumentError, "DOCUMENT_SCAN must be one of: #{DOCUMENT_SCAN_MODES.join(', ')}"
    end

    return if @patient_ids.empty?

    missing = @patient_ids.reject do |patient_id|
      Patient.unscoped.exists?(patient_id: patient_id)
    end
    raise ArgumentError, "Patient(s) not found: #{missing.join(', ')}" if missing.any?
  end

  def print_header
    puts "\n===== Patient Sync Threshold Report ====="
    puts "Patients: #{@patient_ids.any? ? @patient_ids.join(', ') : 'all patients'}"
    puts "Observation condition: > #{OBSERVATION_LIMIT}"
    puts "Order condition: > #{ORDER_LIMIT}"
    puts "Document condition: > #{DOCUMENT_LIMIT_BYTES} bytes (7 MiB)"
    puts "Document scan: #{@document_scan}"
    puts "Output: #{@output_path}"
    puts
  end

  def filtered_scope(scope, key)
    return scope if @patient_ids.empty?

    scope.where(key => @patient_ids)
  end

  def count_overages(scope, key, limit)
    filtered_scope(scope, key)
      .group(key)
      .having('COUNT(*) > ?', limit)
      .count
      .transform_keys(&:to_i)
  end

  def initialize_count_matches(observation_overages, order_overages)
    (observation_overages.keys | order_overages.keys).to_h do |patient_id|
      [
        patient_id,
        {
          observation_count: observation_overages[patient_id],
          order_count: order_overages[patient_id],
          document_bytes: nil
        }
      ]
    end
  end

  def scan_documents(matches, count_candidate_ids)
    return [] if @document_scan == 'none'

    ids = document_scan_ids(count_candidate_ids)
    total = ids.count
    checked = 0
    errors = []

    ids.find_each(batch_size: @batch_size) do |patient|
      patient_id = patient.patient_id.to_i
      record = BuildPatientRecordService.build_patient_record(patient_id)

      if record
        payload_bytes = estimated_single_document_payload_bytes(record)
        if payload_bytes > DOCUMENT_LIMIT_BYTES
          matches[patient_id] ||= {
            observation_count: nil,
            order_count: nil,
            document_bytes: nil
          }
          matches[patient_id][:document_bytes] = payload_bytes
        end
      else
        errors << [patient_id, 'BuildPatientRecordService returned no document']
      end
    rescue StandardError => e
      errors << [patient_id, "#{e.class}: #{e.message}"]
    ensure
      checked += 1
      print_document_progress(checked, total) if progress_due?(checked, total)
    end

    errors
  end

  def document_scan_ids(count_candidate_ids)
    scope = Patient
            .where(patient_id: PatientSyncReconciler.eligible_patient_ids)
            .select(:patient_id)
            .order(:patient_id)

    if @patient_ids.any?
      scope.where(patient_id: @patient_ids)
    elsif @document_scan == 'candidates'
      scope.where(patient_id: count_candidate_ids)
    else
      scope
    end
  end

  def estimated_single_document_payload_bytes(record)
    # Mirrors Sync::BaseSyncJob#estimated_bulk_payload_bytes for one document.
    12 + record.to_json.bytesize + 1
  end

  def progress_due?(checked, total)
    (checked % @progress_every).zero? || checked == total
  end

  def print_document_progress(checked, total)
    percent = total.positive? ? ((checked.to_f / total) * 100).round(1) : 100.0
    puts "Document scan: #{checked}/#{total} (#{percent}%)"
  end

  def populate_all_counts(matches)
    patient_ids = matches.keys
    return if patient_ids.empty?

    observation_counts = counts_for_ids(
      Observation.unscoped,
      :person_id,
      patient_ids
    )
    order_counts = counts_for_ids(Order.unscoped, :patient_id, patient_ids)

    matches.each do |patient_id, row|
      row[:observation_count] = observation_counts.fetch(patient_id, 0)
      row[:order_count] = order_counts.fetch(patient_id, 0)
    end
  end

  def counts_for_ids(scope, key, patient_ids)
    patient_ids.each_slice(5_000).each_with_object({}) do |ids, counts|
      grouped = scope.where(key => ids).group(key).count
      grouped.each { |patient_id, count| counts[patient_id.to_i] = count.to_i }
    end
  end

  def write_report(matches)
    FileUtils.mkdir_p(File.dirname(@output_path))

    CSV.open(@output_path, 'w', write_headers: true, headers: %w[
      patient_id observation_count order_count document_bytes document_mib
      over_50000_observations over_20000_orders over_7_mib_document
      matched_conditions
    ]) do |csv|
      matches.sort.each do |patient_id, row|
        observation_over = row[:observation_count].to_i > OBSERVATION_LIMIT
        order_over = row[:order_count].to_i > ORDER_LIMIT
        document_over = row[:document_bytes].to_i > DOCUMENT_LIMIT_BYTES

        csv << [
          patient_id,
          row[:observation_count],
          row[:order_count],
          row[:document_bytes],
          mib(row[:document_bytes]),
          observation_over,
          order_over,
          document_over,
          matched_conditions(observation_over, order_over, document_over)
        ]
      end
    end
  end

  def write_errors(errors)
    return FileUtils.rm_f(@error_path) if errors.empty?

    CSV.open(@error_path, 'w', write_headers: true, headers: %w[
      patient_id error
    ]) do |csv|
      errors.each { |error| csv << error }
    end
  end

  def mib(bytes)
    return nil if bytes.blank?

    format('%.3f', bytes.to_f / (1024 * 1024))
  end

  def matched_conditions(observation_over, order_over, document_over)
    conditions = []
    conditions << 'observations' if observation_over
    conditions << 'orders' if order_over
    conditions << 'document' if document_over
    conditions.join('|')
  end

  def print_summary(matches, errors)
    observation_ids = matching_ids(matches) do |row|
      row[:observation_count].to_i > OBSERVATION_LIMIT
    end
    order_ids = matching_ids(matches) do |row|
      row[:order_count].to_i > ORDER_LIMIT
    end
    document_ids = matching_ids(matches) do |row|
      row[:document_bytes].to_i > DOCUMENT_LIMIT_BYTES
    end

    puts "\n===== Results ====="
    print_ids('Above 50,000 observations', observation_ids)
    print_ids('Above 20,000 orders', order_ids)
    print_ids('Above 7 MiB document', document_ids)
    puts "Unique matching patients: #{matches.size}"
    puts "CSV: #{@output_path}"
    puts "Document build errors: #{errors.size}"
    puts "Error CSV: #{@error_path}" if errors.any?
  end

  def matching_ids(matches, &block)
    matches.select { |_patient_id, row| block.call(row) }.keys.sort
  end

  def print_ids(label, ids)
    preview = ids.first(200).join(', ')
    suffix = ids.size > 200 ? " ... (#{ids.size - 200} more in CSV)" : ''
    puts "#{label}: #{ids.size}"
    puts "  IDs: #{preview}#{suffix}" if ids.any?
  end

  def error_path_for(output_path)
    extension = File.extname(output_path)
    base = extension.empty? ? output_path : output_path.delete_suffix(extension)
    "#{base}_errors.csv"
  end
end

namespace :patient_sync do
  desc 'List patients above historical observation, order, or document-size thresholds'
  task threshold_report: :environment do
    PatientSyncThresholdReport.new.run
  end
end
