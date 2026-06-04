# frozen_string_literal: true

module PatientRecordSearchFields
  PATIENT_RECORD_DB = 'patients_records'

  COUCHDB_INDEXES = [
    { name: 'idx_patient_identifier', fields: ['ID'] },
    { name: 'idx_ncd_id', fields: ['NcdID'] },
    { name: 'idx_national_id', fields: ['nationalID'] },
    { name: 'idx_ichis_id', fields: ['ichisID'] },
    { name: 'idx_given_name_search', fields: ['given_name_search'] },
    { name: 'idx_family_name_search', fields: ['family_name_search'] },
    { name: 'idx_full_name_search', fields: ['full_name_search'] },
    { name: 'idx_location_full_name_search', fields: ['location_id_search', 'full_name_search'] },
    { name: 'idx_location_given_name_search', fields: ['location_id_search', 'given_name_search'] },
    { name: 'idx_location_family_name_search', fields: ['location_id_search', 'family_name_search'] }
  ].freeze

  @indexed_databases = {}

  module_function

  def normalize!(record)
    return record unless record.respond_to?(:[]=)

    info = fetch_hash(record, :personInformation) || {}
    person = fetch_hash(record, :person) || {}
    person_name = Array(fetch_value(person, :names)).first || {}

    given = first_present(
      fetch_value(info, :given_name),
      fetch_value(record, :given_name),
      fetch_value(person_name, :given_name),
      fetch_value(person_name, :first_name)
    )
    middle = first_present(
      fetch_value(info, :middle_name),
      fetch_value(record, :middle_name),
      fetch_value(person_name, :middle_name)
    )
    family = first_present(
      fetch_value(info, :family_name),
      fetch_value(record, :family_name),
      fetch_value(person_name, :family_name),
      fetch_value(person_name, :last_name)
    )
    gender = first_present(
      fetch_value(info, :gender),
      fetch_value(record, :gender),
      fetch_value(person, :gender)
    )
    location_id = first_present(
      fetch_value(record, :location_id),
      fetch_value(record, :deleted_location_id)
    )

    given_search = normalize_text(given)
    middle_search = normalize_text(middle)
    family_search = normalize_text(family)

    record['given_name_search'] = given_search
    record['middle_name_search'] = middle_search
    record['family_name_search'] = family_search
    record['full_name_search'] = join_search_parts(given_search, family_search)
    record['full_name_with_middle_search'] = join_search_parts(given_search, middle_search, family_search)
    record['gender_search'] = normalize_text(gender)
    record['location_id_search'] = location_id.to_s.strip

    record
  end

  def normalize_if_patient_record!(record, db_name)
    return record unless db_name.to_s == PATIENT_RECORD_DB

    normalize!(record)
  end

  def ensure_couchdb_indexes!(db_url, logger: Rails.logger, force: false)
    return if db_url.blank?
    return if @indexed_databases[db_url] && !force

    COUCHDB_INDEXES.each do |definition|
      RestClient.post(
        "#{db_url}/_index",
        {
          type: 'json',
          name: definition[:name],
          ddoc: definition[:name],
          index: { fields: definition[:fields] }
        }.to_json,
        { content_type: :json, accept: :json }
      )
    rescue StandardError => e
      logger&.warn("Could not create CouchDB patient search index #{definition[:name]}: #{e.message}")
    end

    @indexed_databases[db_url] = true
  end

  def normalize_text(value)
    text = value.to_s
    text = I18n.transliterate(text) if defined?(I18n)
    text.downcase.gsub(/[^a-z0-9]+/, ' ').squish
  end

  def join_search_parts(*parts)
    parts.map(&:to_s).reject(&:blank?).join(' ')
  end

  def fetch_hash(record, key)
    value = fetch_value(record, key)
    value.respond_to?(:[]) ? value : nil
  end

  def fetch_value(record, key)
    return nil unless record.respond_to?(:[])

    record[key] || record[key.to_s]
  end

  def first_present(*values)
    values.find(&:present?)
  end
end
