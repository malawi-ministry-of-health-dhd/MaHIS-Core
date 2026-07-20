# frozen_string_literal: true

class LabAccessionNumberPoolService
  include CouchdbSync

  DB_NAME = 'lab_accession_numbers'
  FACILITIES_DB_NAME = 'facilities'
  DOC_TYPE = 'lab_accession_number'
  DEFAULT_TARGET_COUNT = 200
  DAY_NUMBERING_SYSTEM = %w[1 2 3 4 5 6 7 8 9 A B C E F G H Y J K Z M N O P Q R S T V W X].freeze

  class AccessionPoolError < StandardError; end

  def ensure_pool_for_location(location_id:, target_count: DEFAULT_TARGET_COUNT, count: nil)
    location_id = normalize_location_id(location_id)
    raise AccessionPoolError, 'location_id is required' if location_id.blank?
    raise AccessionPoolError, 'CouchDB is not configured' unless couchdb_configured?

    ensure_location_eligible!(location_id)
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

  def reserve_for_device(location_id:, device_id:, count: 25)
    location_id = normalize_location_id(location_id)
    device_id = device_id.to_s.strip
    count = positive_integer(count, 25)

    raise AccessionPoolError, 'location_id is required' if location_id.blank?
    raise AccessionPoolError, 'device_id is required' if device_id.blank?

    ensure_location_eligible!(location_id)
    reserved_at = Time.current.iso8601

    # Reserve existing central-pool documents instead of generating a separate
    # device-only sequence. Updating the existing _rev makes the claim atomic:
    # if two devices select the same number, only one PUT succeeds and the other
    # continues with another available document.
    ensure_pool_for_location(location_id: location_id, target_count: [configured_target_count, count].max)
    documents = claim_available_documents(location_id, device_id, count, reserved_at)

    documents
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
    # Clients released before central reservation support may still return an
    # accession whose server document says "available". Keep accepting those
    # legacy offline orders during rollout; consume! immediately records the
    # offline order, while the consumed branch below prevents later reuse.

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

    consumed_at = Time.current.iso8601
    update_document(doc.merge(
      'assigned' => true,
      'status' => 'consumed',
      'used_by_offline_id' => offline_id,
      'patient_id' => patient_id,
      'order_id' => order_id,
      'used_at' => consumed_at,
      'consumed_at' => consumed_at
    ))
    top_up_after_consume(location_id)
    true
  rescue StandardError => e
    log(:warn, "Could not mark accession number #{accession_number} consumed: #{e.message}")
    false
  end

  # Resolves the local order_id that #consume! recorded against the given
  # offline_id. Lets the result-save path recover a test for a result that only
  # carries an offline_id (no per-test obs id) when its order was already saved
  # in an earlier sync. Returns nil when unknown.
  def order_id_for_offline_id(offline_id)
    offline_id = offline_id.to_s.strip
    return nil if offline_id.blank? || !couchdb_configured?

    response = RestClient.post(
      couchdb_url(DB_NAME, '_find'),
      { selector: { used_by_offline_id: offline_id }, fields: %w[order_id], limit: 1 }.to_json,
      { content_type: :json, accept: :json }
    )
    JSON.parse(response.body).fetch('docs', []).first&.dig('order_id')
  rescue StandardError => e
    log(:warn, "Could not resolve order for offline_id #{offline_id}: #{e.message}")
    nil
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
               GlobalProperty.find_by(property: 'site_prefix', location_id: location_id.to_i)
    value = property&.property_value.to_s.strip

    raise AccessionPoolError, "Global property 'site_prefix' not set for location #{location_id}" if value.blank?

    value
  end

  def location_ids_for_site_prefixes
    site_prefix_location_ids & dde_activated_location_ids
  end

  def site_prefix_location_ids
    @site_prefix_location_ids ||= GlobalProperty.where(property: 'site_prefix')
                                                .where.not(property_value: [nil, ''])
                                                .pluck(:location_id)
                                                .compact
                                                .map(&:to_s)
                                                .reject(&:blank?)
                                                .uniq
  end

  def ensure_location_eligible!(location_id)
    unless site_prefix_location_ids.include?(location_id.to_s)
      raise AccessionPoolError, "Global property 'site_prefix' not set for location #{location_id}"
    end

    return if dde_activated_location_ids.include?(location_id.to_s)

    raise AccessionPoolError, "DDE activation is not enabled for location #{location_id}"
  end

  def dde_activated_location_ids
    return @dde_activated_location_ids if defined?(@dde_activated_location_ids)
    return [] unless couchdb_configured?

    response = RestClient::Request.execute(
      method: :get,
      url: "#{couchdb_url(FACILITIES_DB_NAME)}/_all_docs?include_docs=true",
      timeout: 5,
      open_timeout: 5
    )
    result = JSON.parse(response.body)

    @dde_activated_location_ids = result.fetch('rows', []).filter_map do |row|
      doc = row['doc']
      next unless doc
      next if doc['_id'].to_s.start_with?('_design/')
      next unless dde_activated?(doc)

      facility_location_id(doc)
    end.map(&:to_s).reject(&:blank?).uniq
  rescue RestClient::NotFound
    log(:warn, "Facilities database '#{FACILITIES_DB_NAME}' not found; lab accession number top-up skipped")
    @dde_activated_location_ids = []
  rescue StandardError => e
    log(:warn, "Could not fetch DDE-activated facilities for lab accession number top-up: #{e.message}")
    @dde_activated_location_ids = []
  end

  def facility_location_id(doc)
    doc['location_id'].presence || doc['_id'].to_s[/\Afacility_(.+)\z/, 1]
  end

  def dde_activated?(doc)
    value = doc['dde_activated']
    value == true || value.to_s.strip.casecmp('true').zero?
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
        'assigned' => false,
        'status' => 'available',
        'generated_at' => generated_at
      }
    end
  end

  def top_up_after_consume(location_id)
    ensure_pool_for_location(location_id: location_id, target_count: configured_target_count)
  rescue StandardError => e
    log(:warn, "Could not top up lab accession numbers after consuming one for location #{location_id}: #{e.message}")
  end

  def claim_available_documents(location_id, device_id, count, reserved_at)
    claimed = []
    attempts = 0

    while claimed.length < count && attempts < 5
      attempts += 1
      candidates = available_documents(location_id, count - claimed.length)
      break if candidates.empty?

      candidates.each do |document|
        claimed_document = claim_available_document(document, device_id, reserved_at)
        claimed << claimed_document if claimed_document
        break if claimed.length >= count
      end
    end

    claimed
  end

  def available_documents(location_id, limit)
    response = RestClient.post(
      couchdb_url(DB_NAME, '_find'),
      {
        selector: {
          type: DOC_TYPE,
          location_id: location_id.to_s,
          status: 'available'
        },
        limit: [limit * 2, 10].max
      }.to_json,
      { content_type: :json, accept: :json }
    )

    JSON.parse(response.body).fetch('docs', []).sort_by { |document| document['_id'].to_s }
  end

  def claim_available_document(document, device_id, reserved_at)
    claimed = document.merge(
      'assigned' => false,
      'status' => 'reserved',
      'assigned_to_device_id' => device_id,
      'assigned_at' => reserved_at,
      'reservation_source' => 'api'
    )

    response = update_document(claimed)
    claimed['_rev'] = JSON.parse(response.body)['rev']
    claimed
  rescue RestClient::Conflict, RestClient::PreconditionFailed
    nil
  end

  def configured_target_count
    value = if defined?(CouchdbSync::CONFIG)
              CouchdbSync::CONFIG['LAB_ACCESSION_TARGET_COUNT']
            end

    positive_integer(value, DEFAULT_TARGET_COUNT)
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
    create_index(%w[used_by_offline_id], 'idx_used_by_offline_id')
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
