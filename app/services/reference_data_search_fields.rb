# frozen_string_literal: true

module ReferenceDataSearchFields
  TEXT_FIELD_CONFIG = {
    'concept_names' => {
      'name_search' => :name
    },
    'concept_sets' => {
      'concept_set_name_search' => :concept_set_name
    },
    'diagnoses' => {
      'name_search' => :name,
      'code_search' => :code
    },
    'villages' => {
      'name_search' => :name,
      'parent_location_search' => :parent_location
    },
    'traditional_authorities' => {
      'name_search' => :name,
      'parent_location_search' => :parent_location
    },
    'districts' => {
      'name_search' => :name,
      'parent_location_search' => :parent_location
    },
    'wards' => {
      'name_search' => :name,
      'parent_location_search' => :parent_location
    },
    'sections' => {
      'name_search' => :name,
      'parent_location_search' => :parent_location
    }
  }.freeze

  COUCHDB_INDEXES = {
    'concept_names' => [
      { name: 'idx_concept_id', fields: ['concept_id'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_concept_id_name_search', fields: ['concept_id', 'name_search'] },
      { name: 'idx_name', fields: ['name'] },
      { name: 'idx_concept_id_name', fields: ['concept_id', 'name'] }
    ],
    'concept_sets' => [
      { name: 'idx_concept_set_id', fields: ['concept_set_id'] },
      { name: 'idx_concept_set_name_search', fields: ['concept_set_name_search'] },
      { name: 'idx_concept_set_name', fields: ['concept_set_name'] }
    ],
    'diagnoses' => [
      { name: 'idx_code', fields: ['code'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_code_search', fields: ['code_search'] },
      { name: 'idx_name', fields: ['name'] },
      { name: 'idx_code_name', fields: ['code', 'name'] }
    ],
    'villages' => [
      { name: 'idx_location_id', fields: ['location_id'] },
      { name: 'idx_parent_location', fields: ['parent_location'] },
      { name: 'idx_parent_location_search', fields: ['parent_location_search'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_parent_location_name_search', fields: ['parent_location_search', 'name_search'] }
    ],
    'traditional_authorities' => [
      { name: 'idx_location_id', fields: ['location_id'] },
      { name: 'idx_parent_location', fields: ['parent_location'] },
      { name: 'idx_parent_location_search', fields: ['parent_location_search'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_parent_location_name_search', fields: ['parent_location_search', 'name_search'] }
    ],
    'districts' => [
      { name: 'idx_location_id', fields: ['location_id'] },
      { name: 'idx_parent_location', fields: ['parent_location'] },
      { name: 'idx_parent_location_search', fields: ['parent_location_search'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_parent_location_name_search', fields: ['parent_location_search', 'name_search'] }
    ],
    'wards' => [
      { name: 'idx_location_id', fields: ['location_id'] },
      { name: 'idx_parent_location', fields: ['parent_location'] },
      { name: 'idx_parent_location_search', fields: ['parent_location_search'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_parent_location_name_search', fields: ['parent_location_search', 'name_search'] }
    ],
    'sections' => [
      { name: 'idx_location_id', fields: ['location_id'] },
      { name: 'idx_parent_location', fields: ['parent_location'] },
      { name: 'idx_parent_location_search', fields: ['parent_location_search'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_parent_location_name_search', fields: ['parent_location_search', 'name_search'] }
    ],
    # Databases below carry no normalised text fields, so they are absent from
    # TEXT_FIELD_CONFIG — but they still need indexes, and the backend is the only
    # party that should be creating them on a shared CouchDB. Names and fields
    # mirror the client's DATABASE_INDEX_CONFIG exactly (MAHIS
    # database_index_manager.ts); if the two ever disagree the ensurer will fight
    # whatever the client created, re-POSTing on every sync batch.
    'visits' => [
      { name: 'idx_identifier', fields: ['identifier'] },
      { name: 'idx_identifier_date_stopped', fields: ['identifier', 'date_stopped'] },
      { name: 'idx_program_identifier_date_stopped', fields: ['program_id', 'identifier', 'date_stopped'] },
      { name: 'idx_location_program_date_started', fields: ['location_id', 'program_id', 'date_started'] },
      { name: 'idx_date_started', fields: ['date_started'] }
    ],
    'dde' => [
      { name: 'idx_type', fields: ['type'] },
      { name: 'idx_status', fields: ['status'] },
      { name: 'idx_type_status', fields: ['type', 'status'] },
      { name: 'idx_assigned_to_status', fields: ['assignedTo', 'status'] }
    ],
    'lab_accession_numbers' => [
      { name: 'idx_type', fields: ['type'] },
      { name: 'idx_status', fields: ['status'] },
      { name: 'idx_type_location_status', fields: ['type', 'location_id', 'status'] },
      { name: 'idx_assigned_device_status', fields: ['assigned_to_device_id', 'status'] },
      { name: 'idx_used_by_offline_id', fields: ['used_by_offline_id'] }
    ],
    'regimens' => [
      { name: 'idx_id', fields: ['_id'] },
      { name: 'idx_min_weight', fields: ['min_weight'] },
      { name: 'idx_max_weight', fields: ['max_weight'] },
      { name: 'idx_weight_range', fields: ['min_weight', 'max_weight'] }
    ],
    'custom_regimen_ingredients' => [
      { name: 'idx_drug_id', fields: ['drug_id'] },
      { name: 'idx_name', fields: ['name'] },
      { name: 'idx_concept_id', fields: ['concept_id'] }
    ],
    'mnh_stats' => [
      { name: 'idx_location_id', fields: ['location_id'] },
      { name: 'idx_location_program', fields: ['location_id', 'program_key'] },
      { name: 'idx_location_program_date', fields: ['location_id', 'program_key', 'date'] }
    ]
  }.freeze

  @indexed_databases = {}

  module_function

  def supported_database?(db_name)
    TEXT_FIELD_CONFIG.key?(db_name.to_s)
  end

  def normalize_if_supported!(record, db_name)
    return record unless supported_database?(db_name)

    normalize!(record, db_name)
  end

  def normalize!(record, db_name)
    return record unless record.respond_to?(:[]=)

    TEXT_FIELD_CONFIG.fetch(db_name.to_s).each do |search_field, source_field|
      value = fetch_value(record, source_field)
      record[search_field] = search_field.end_with?('_search') && search_field.include?('parent_location') ? value.to_s.strip : normalize_text(value)
    end

    record
  end

  # Gated on having index definitions, NOT on supported_database?. Those are two
  # different things: supported_database? means "this database has text fields we
  # normalise", while index creation only needs index definitions. Several
  # databases (visits, dde, lab_accession_numbers, regimens, mnh_stats,
  # custom_regimen_ingredients) need indexes but no text normalisation, and the
  # old gate silently skipped them — which is why the client had to create their
  # indexes itself, from every device, against the shared CouchDB.
  def indexable_database?(db_name)
    COUCHDB_INDEXES.key?(db_name.to_s)
  end

  def ensure_couchdb_indexes!(db_url, db_name, logger: Rails.logger, force: false)
    return if db_url.blank?
    return unless indexable_database?(db_name)

    CouchdbIndexEnsurer.ensure!(
      db_url,
      COUCHDB_INDEXES.fetch(db_name.to_s, []),
      cache: @indexed_databases,
      cache_key: [db_url, db_name.to_s],
      logger:,
      force:,
      label: "CouchDB #{db_name}"
    )
  end

  def normalize_text(value)
    text = value.to_s
    text = I18n.transliterate(text) if defined?(I18n)
    text.downcase.gsub(/[^a-z0-9]+/, ' ').squish
  end

  def fetch_value(record, key)
    return nil unless record.respond_to?(:[])

    record[key] || record[key.to_s]
  end
end
