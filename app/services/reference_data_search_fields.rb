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
      { name: 'idx_concept_id_name_search', fields: ['concept_id', 'name_search'] }
    ],
    'concept_sets' => [
      { name: 'idx_concept_set_id', fields: ['concept_set_id'] },
      { name: 'idx_concept_set_name_search', fields: ['concept_set_name_search'] }
    ],
    'diagnoses' => [
      { name: 'idx_code', fields: ['code'] },
      { name: 'idx_name_search', fields: ['name_search'] },
      { name: 'idx_code_search', fields: ['code_search'] }
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

  def ensure_couchdb_indexes!(db_url, db_name, logger: Rails.logger, force: false)
    return if db_url.blank?
    return unless supported_database?(db_name)

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
