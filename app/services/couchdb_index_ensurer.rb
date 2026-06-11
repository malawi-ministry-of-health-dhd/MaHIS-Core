# frozen_string_literal: true

module CouchdbIndexEnsurer
  module_function

  def ensure!(db_url, definitions, cache:, cache_key:, logger: Rails.logger, force: false, label: 'CouchDB')
    return true if db_url.blank?
    return true if cache[cache_key] && !force

    missing = missing_definitions(db_url, definitions, logger:, label:)
    if missing.empty?
      cache[cache_key] = true
      return true
    end

    missing.each do |definition|
      create_index(db_url, definition, logger:, label:)
    end

    remaining = missing_definitions(db_url, definitions, logger:, label:)
    if remaining.empty?
      cache[cache_key] = true
      true
    else
      cache.delete(cache_key)
      logger&.warn("#{label} indexes still missing after ensure: #{remaining.map { |definition| definition[:name] }.join(', ')}")
      false
    end
  end

  def missing_definitions(db_url, definitions, logger:, label:)
    existing_indexes = fetch_indexes(db_url, logger:, label:)

    definitions.reject do |definition|
      existing_indexes.any? { |index| index_matches_definition?(index, definition) }
    end
  end

  def fetch_indexes(db_url, logger:, label:)
    response = RestClient.get("#{db_url}/_index", accept: :json)
    JSON.parse(response.body).fetch('indexes', [])
  rescue StandardError => e
    logger&.warn("#{label} indexes could not be inspected: #{e.class}: #{e.message}")
    []
  end

  def create_index(db_url, definition, logger:, label:)
    logger&.info("#{label}: creating missing CouchDB index #{definition[:name]}")

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
    logger&.warn("#{label}: could not create CouchDB index #{definition[:name]}: #{e.class}: #{e.message}")
  end

  def index_matches_definition?(index, definition)
    return false unless index['type'].to_s == 'json'

    expected_name = definition[:name].to_s
    name_matches = index['name'].to_s == expected_name
    ddoc_matches = normalize_ddoc(index['ddoc']) == expected_name

    (name_matches || ddoc_matches) && fields_for(index) == definition[:fields].map(&:to_s)
  end

  def fields_for(index)
    Array(index.dig('def', 'fields')).map do |field|
      field.is_a?(Hash) ? field.keys.first.to_s : field.to_s
    end
  end

  def normalize_ddoc(ddoc)
    ddoc.to_s.sub(%r{\A_design/}, '').sub(%r{\A/_design/}, '')
  end
end
