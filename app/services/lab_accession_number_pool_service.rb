# frozen_string_literal: true

class LabAccessionNumberPoolService
  include CouchdbSync

  DB_NAME = 'lab_accession_numbers'
  DOC_TYPE = 'lab_accession_number'
  DEFAULT_TARGET_COUNT = 200
  DAY_NUMBERING_SYSTEM = %w[1 2 3 4 5 6 7 8 9 A B C E F G H Y J K Z M N O P Q R S T V W X].freeze

  class AccessionPoolError < StandardError; end

  def ensure_pool_for_location(location_id:, target_count: DEFAULT_TARGET_COUNT, count: nil)
    location_id = normalize_location_id(location_id)
    raise AccessionPoolError, 'location_id is required' if location_id.blank?
    raise AccessionPoolError, 'CouchDB is not configured' unless couchdb_configured?

    ensure_database_and_indexes
    facility_prefix = facility_prefix_for!(location_id)
    target_count = positive_integer(target_count, DEFAULT_TARGET_COUNT)
    explicit_count = positive_integer(count, nil)
    current_available = available_count(location_id, limit: target_count)
    needed = explicit_count || [target_count - current_available, 0].max

    documents = needed.positive? ? generate_documents(location_id, facility_prefix, needed) : []
    sync_result = append_documents(documents)

    {
      database: DB_NAME,
      location_id: location_id,
      facility_prefix: facility_prefix,
      target_count: target_count,
      available_before: current_available,
      generated: documents.length,
      inserted: sync_result[:inserted],
      skipped: sync_result[:skipped],
      errors: sync_result[:errors]
    }
  end

  def ensure_pool_for_all_facilities(target_count: DEFAULT_TARGET_COUNT)
    location_ids_for_site_prefixes.each_with_object({}) do |location_id, results|
      results[location_id] = ensure_pool_for_location(location_id: location_id, target_count: target_count)
    rescue StandardError => e
      log(:error, "Failed to top up lab accession numbers for location #{location_id}: #{e.message}")
      results[location_id] = { error: e.message }
    end
  end

  def validate_usable!(accession_number:, offline_id:, location_id:)
    accession_number = accession_number.to_s.strip
    return true if accession_number.blank?

    doc = fetch_document(accession_number)
    return true unless doc

    doc_location_id = doc['location_id'].to_s
    if location_id.present? && doc_location_id.present? && doc_location_id != normalize_location_id(location_id)
      raise AccessionPoolError, "Accession number #{accession_number} belongs to location #{doc_location_id}"
    end

    status = doc['status'].to_s
    if status == 'available'
      raise AccessionPoolError, "Accession number #{accession_number} has not been reserved by a device"
    end

    if status == 'consumed'
      return true if offline_id.present? && doc['used_by_offline_id'].to_s == offline_id.to_s

      raise AccessionPoolError, "Accession number #{accession_number} has already been consumed"
    end

    used_by = doc['used_by_offline_id'].presence
    if used_by.present? && offline_id.present? && used_by.to_s != offline_id.to_s
      raise AccessionPoolError, "Accession number #{accession_number} is already attached to another offline order"
    end

    true
  end

  def consume!(accession_number:, offline_id:, patient_id:, order_id:, location_id:)
    accession_number = accession_number.to_s.strip
    return false if accession_number.blank?

    doc = fetch_document(accession_number)
    unless doc
      log(:warn, "Accession number #{accession_number} was not found in #{DB_NAME}; allowing legacy/manual accession")
      return false
    end

    validate_usable!(
      accession_number: accession_number,
      offline_id: offline_id,
      location_id: location_id
    )

    update_document(doc.merge(
      'status' => 'consumed',
      'used_by_offline_id' => offline_id,
      'patient_id' => patient_id,
      'order_id' => order_id,
      'consumed_at' => Time.current.iso8601
    ))
    true
  rescue StandardError => e
    log(:warn, "Could not mark accession number #{accession_number} consumed: #{e.message}")
    false
  end

  private

  def positive_integer(value, fallback)
    return fallback if value.blank?

    number = value.to_i
    number.positive? ? number : fallback
  end

  def normalize_location_id(location_id)
    location_id.to_s.strip
  end

  def facility_prefix_for!(location_id)
    property = GlobalProperty.find_by(property: 'site_prefix', location_id: location_id) ||
               GlobalProperty.find_by(property: 'site_prefix', location_id: location_id.to_i) ||
               GlobalProperty.find_by(property: 'site_prefix')
    value = property&.property_value.to_s.strip

    raise AccessionPoolError, "Global property 'site_prefix' not set for location #{location_id}" if value.blank?

    value
  end

  def location_ids_for_site_prefixes
    location_ids = GlobalProperty.where(property: 'site_prefix')
                                 .where.not(property_value: [nil, ''])
                                 .pluck(:location_id)
                                 .compact
                                 .map(&:to_s)
                                 .reject(&:blank?)
                                 .uniq

    return location_ids if location_ids.any?

    fallback = GlobalProperty.find_by(property: 'current_health_center_id')&.property_value
    fallback.present? ? [fallback.to_s] : []
  end

  def generate_documents(location_id, facility_prefix, count)
    date = Date.current
    generated_at = Time.current.iso8601

    next_accession_numbers(date, facility_prefix, count).map do |accession_number|
      {
        '_id' => accession_number,
        'type' => DOC_TYPE,
        'accession_number' => accession_number,
        'facility_prefix' => facility_prefix,
        'location_id' => location_id.to_s,
        'date' => date.iso8601,
        'status' => 'available',
        'generated_at' => generated_at
      }
    end
  end

  def next_accession_numbers(date, facility_prefix, count)
    counter = find_counter(date)

    counter.with_lock do
      Array.new(count) do
        value = counter.value.to_i
        counter.value = value + 1
        format_accession_number(date, facility_prefix, value)
      end.tap { counter.save! }
    end
  end

  def find_counter(date)
    Lab::LabAccessionNumberCounter.find_or_create_by!(date: date) do |counter|
      counter.value = 1
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def format_accession_number(date, facility_prefix, counter)
    year = (date.year % 100).to_s.rjust(2, '0')
    month = DAY_NUMBERING_SYSTEM[date.month - 1]
    day = DAY_NUMBERING_SYSTEM[date.day - 1]

    "X#{facility_prefix}#{year}#{month}#{day}#{counter}"
  end

  def ensure_database_and_indexes
    ensure_db_exists(DB_NAME)
    create_index(%w[type location_id status], 'idx_type_location_status')
    create_index(%w[assigned_to_device_id status], 'idx_assigned_device_status')
    create_index(%w[status], 'idx_status')
  end

  def create_index(fields, name)
    RestClient.post(
      couchdb_url(DB_NAME, '_index'),
      {
        index: { fields: fields },
        name: name,
        type: 'json'
      }.to_json,
      { content_type: :json, accept: :json }
    )
  rescue RestClient::Conflict, RestClient::PreconditionFailed
    true
  rescue StandardError => e
    log(:warn, "Could not create #{DB_NAME} index #{name}: #{e.message}")
    false
  end

  def available_count(location_id, limit:)
    return 0 unless couchdb_configured?

    ensure_database_and_indexes
    response = RestClient.post(
      couchdb_url(DB_NAME, '_find'),
      {
        selector: {
          type: DOC_TYPE,
          location_id: location_id.to_s,
          status: 'available'
        },
        limit: limit
      }.to_json,
      { content_type: :json, accept: :json }
    )
    JSON.parse(response.body).fetch('docs', []).length
  rescue RestClient::NotFound
    0
  rescue StandardError => e
    log(:warn, "Could not count available lab accession numbers for location #{location_id}: #{e.message}")
    0
  end

  def append_documents(documents)
    return { inserted: 0, skipped: 0, errors: [] } if documents.empty? || !couchdb_configured?

    ensure_database_and_indexes
    response = RestClient.post(
      couchdb_url(DB_NAME, '_bulk_docs'),
      { docs: documents }.to_json,
      { content_type: :json, accept: :json }
    )
    results = JSON.parse(response.body)
    conflicts = results.count { |result| result['error'] == 'conflict' }
    errors = results.select { |result| result['error'].present? && result['error'] != 'conflict' }
                    .map { |result| "Doc #{result['id']}: #{result['error']} - #{result['reason']}" }

    {
      inserted: results.count { |result| result['ok'] },
      skipped: conflicts,
      errors: errors
    }
  end

  def fetch_document(accession_number)
    response = RestClient.get(couchdb_url(DB_NAME, URI.encode_www_form_component(accession_number)))
    JSON.parse(response.body)
  rescue RestClient::NotFound
    nil
  rescue StandardError => e
    log(:warn, "Could not read accession number #{accession_number} from #{DB_NAME}: #{e.message}")
    nil
  end

  def update_document(doc)
    RestClient.put(
      couchdb_url(DB_NAME, URI.encode_www_form_component(doc.fetch('_id'))),
      doc.to_json,
      { content_type: :json, accept: :json }
    )
  end

  def log(level, message)
    logger = defined?(Sidekiq) && Sidekiq.respond_to?(:logger) ? Sidekiq.logger : Rails.logger
    logger.public_send(level, message)
  end
end
