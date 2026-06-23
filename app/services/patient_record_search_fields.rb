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
    # NCD dashboard indexes now live on the dedicated ncd_patient_index database
    # (see NcdService::NcdPatientIndex), not on patients_records.
  ].freeze

  NCD_PROGRAM_ID = 32
  NCD_COMPLICATIONS_ENCOUNTER_TYPE_ID = 28
  NCD_PRIMARY_DIAGNOSIS_CONCEPT_NAME = 'Primary diagnosis'

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
    # NCD summary fields are no longer stamped onto patients_records documents.
    # They are projected into the dedicated ncd_patient_index database instead
    # (PatientRecordSearchFields.ncd_projection + NcdService::NcdPatientIndex).

    record
  end

  def normalize_if_patient_record!(record, db_name)
    return record unless db_name.to_s == PATIENT_RECORD_DB

    normalize!(record)
  end

  def ensure_couchdb_indexes!(db_url, logger: Rails.logger, force: false)
    CouchdbIndexEnsurer.ensure!(
      db_url,
      COUCHDB_INDEXES,
      cache: @indexed_databases,
      cache_key: db_url,
      logger: logger,
      force: force,
      label: 'CouchDB patient search'
    )
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

  # Build a standalone NCD summary document for a patient record, suitable for
  # storing in the dedicated `ncd_patient_index` CouchDB database instead of
  # stamping these fields onto the (large) patients_records document. Returns
  # nil when the record is not an NCD patient, so callers can delete/skip.
  def ncd_projection(record)
    return nil unless record.respond_to?(:[])
    return nil unless ncd_patient?(record)

    info = fetch_hash(record, :personInformation) || {}
    person = fetch_hash(record, :person) || {}
    gender = first_present(
      fetch_value(info, :gender),
      fetch_value(record, :gender),
      fetch_value(person, :gender)
    )
    location_id = first_present(
      fetch_value(record, :location_id),
      fetch_value(record, :deleted_location_id)
    )
    patient_id = first_present(
      fetch_value(record, :patientID),
      fetch_value(record, :ID),
      fetch_value(record, :_id)
    )
    return nil if patient_id.blank?

    {
      '_id' => patient_id.to_s,
      'type' => 'ncd_patient',
      'patientID' => patient_id,
      'ncd_active' => true,
      'ncd_location_id' => ncd_location_id(record, location_id).to_s.strip,
      'ncd_gender' => gender.to_s.strip,
      'ncd_pending_id' => ncd_pending_id?(record),
      'ncd_has_pending_dispensation' => ncd_pending_dispensation?(record),
      'ncd_last_dispensation_date' => ncd_last_dispensation_date(record),
      'ncd_has_complications' => ncd_complications?(record),
      'ncd_last_visit_date' => ncd_last_visit_date(record),
      'ncd_latest_primary_diagnosis' => ncd_latest_primary_diagnosis(record),
      'ncd_observation_quarters' => ncd_observation_quarters(record),
      'ncd_diagnosis_quarters' => ncd_diagnosis_quarters(record),
      'NcdID' => fetch_value(record, :NcdID),
      # Display subset for the drill-down patient list, so it can be served
      # entirely from this index (mirrors the fields the frontend renders).
      'personInformation' => {
        'given_name' => fetch_value(info, :given_name),
        'family_name' => fetch_value(info, :family_name),
        'gender' => first_present(fetch_value(info, :gender), gender),
        'birthdate' => fetch_value(info, :birthdate),
        'current_village' => fetch_value(info, :current_village),
        'current_district' => fetch_value(info, :current_district),
        'occupation' => fetch_value(info, :occupation),
        'education_level' => fetch_value(info, :education_level),
        'religion' => fetch_value(info, :religion),
        'marital_status' => fetch_value(info, :marital_status)
      }
    }
  end

  def ncd_patient?(record)
    ncd_identifier = fetch_value(record, :NcdID).to_s.strip
    return true if ncd_identifier.present? && ncd_identifier.casecmp('PENDING') != 0
    return true if fetch_value(record, :needs_ncd_id) == true

    Array(fetch_value(record, :activePrograms)).any? do |program|
      fetch_value(program, :program_id).to_i == NCD_PROGRAM_ID && fetch_value(program, :voided).to_i != 1
    end || ncd_observations(record).any? || ncd_medication_orders(record).any?
  end

  def ncd_location_id(record, fallback)
    ncd_program = Array(fetch_value(record, :activePrograms)).find do |program|
      fetch_value(program, :program_id).to_i == NCD_PROGRAM_ID && fetch_value(program, :location_id).present?
    end
    return fetch_value(ncd_program, :location_id) if ncd_program

    ncd_observations(record).filter_map { |obs| fetch_value(obs, :location_id) }.first || fallback
  end

  def ncd_pending_id?(record)
    return true if fetch_value(record, :needs_ncd_id) == true

    ncd_id = fetch_value(record, :NcdID).to_s.strip
    ncd_id.blank? || ncd_id.casecmp('PENDING').zero?
  end

  def ncd_medication_orders(record)
    medication_order = fetch_value(record, :MedicationOrder) || {}
    orders = Array(fetch_value(medication_order, :saved)) + Array(fetch_value(medication_order, :unsaved))
    orders.select do |order|
      program_id = fetch_value(order, :program_id)
      program_id.blank? || program_id.to_i == NCD_PROGRAM_ID
    end
  end

  def ncd_pending_dispensation?(record)
    ncd_medication_orders(record).any? { |order| fetch_value(order, :quantity).to_f <= 0 }
  end

  def ncd_last_dispensation_date(record)
    order = ncd_medication_orders(record)
            .select { |item| fetch_value(item, :quantity).to_f.positive? }
            .max_by { |item| parse_time(fetch_value(item, :start_date) || fetch_value(item, :encounter_date)) || Time.at(0) }
    date_string(fetch_value(order, :start_date) || fetch_value(order, :encounter_date)) if order
  end

  def ncd_complications?(record)
    Array(fetch_value(record, :observations)).any? do |encounter|
      fetch_value(encounter, :encounter_type).to_i == NCD_COMPLICATIONS_ENCOUNTER_TYPE_ID &&
        fetch_value(encounter, :status).to_s == 'saved' &&
        Array(fetch_value(encounter, :obs)).any?
    end
  end

  def ncd_last_visit_date(record)
    times = ncd_observations(record).filter_map do |obs|
      parse_time(fetch_value(obs, :encounter_datetime) || fetch_value(obs, :obs_datetime))
    end
    date_string(times.max)
  end

  def ncd_latest_primary_diagnosis(record)
    diagnosis = ncd_primary_diagnosis_observations(record).max_by do |obs|
      parse_time(fetch_value(obs, :obs_datetime) || fetch_value(obs, :encounter_datetime)) || Time.at(0)
    end
    fetch_value(diagnosis, :value_coded)&.to_i if diagnosis
  end

  def ncd_observation_quarters(record)
    ncd_observations(record).filter_map do |obs|
      quarter_label(parse_time(fetch_value(obs, :obs_datetime) || fetch_value(obs, :encounter_datetime)))
    end.uniq
  end

  def ncd_diagnosis_quarters(record)
    grouped = {}
    ncd_primary_diagnosis_observations(record).each do |obs|
      time = parse_time(fetch_value(obs, :obs_datetime) || fetch_value(obs, :encounter_datetime))
      label = quarter_label(time)
      next if label.blank?

      current_time = grouped.dig(label, 'time') || Time.at(0)
      if time && time >= current_time
        grouped[label] = {
          'value_coded' => fetch_value(obs, :value_coded)&.to_i,
          'time' => time
        }
      end
    end

    grouped.transform_values { |value| value['value_coded'] }.compact
  end

  def ncd_primary_diagnosis_observations(record)
    ncd_observations(record).select do |obs|
      fetch_value(obs, :concept_name).to_s.casecmp(NCD_PRIMARY_DIAGNOSIS_CONCEPT_NAME).zero?
    end
  end

  def ncd_observations(record)
    Array(fetch_value(record, :observations)).flat_map do |encounter|
      Array(fetch_value(encounter, :obs)).flat_map { |obs| flatten_obs(obs) }
    end.select do |obs|
      program_id = fetch_value(obs, :program_id)
      program_id.blank? || program_id.to_i == NCD_PROGRAM_ID
    end
  end

  def flatten_obs(obs)
    [obs] + Array(fetch_value(obs, :children)).flat_map { |child| flatten_obs(child) }
  end

  def parse_time(value)
    return value if value.is_a?(Time)
    return value.to_time if value.respond_to?(:to_time)
    return nil if value.blank?

    Time.zone ? Time.zone.parse(value.to_s) : Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def date_string(value)
    time = parse_time(value)
    time&.to_date&.to_s
  end

  def quarter_label(time)
    return nil unless time

    date = time.to_date
    "Q#{((date.month - 1) / 3) + 1} #{date.year}"
  end
end
