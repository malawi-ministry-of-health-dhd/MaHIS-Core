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

  # Delete retired index design docs by DESIGN DOC name. CouchDB keeps updating
  # every view in a database on every write, so an index nothing queries still
  # costs write throughput until its design doc is gone. Safe to re-run: a design
  # doc that is already absent is skipped.
  #
  # Matching is deliberately on ddoc ONLY, never on the index name. After index
  # consolidation an index named idx_ID lives inside _design/idx_patient_identifiers,
  # so matching on name would resolve "idx_ID" to the shared group design doc and
  # delete every index in it.
  def prune!(db_url, retired_ddocs, logger: Rails.logger, label: 'CouchDB')
    return 0 if db_url.blank? || retired_ddocs.blank?

    existing_ddocs = fetch_indexes(db_url, logger:, label:)
                     .map { |index| normalize_ddoc(index['ddoc']) }
                     .reject(&:blank?)
                     .uniq
    pruned = 0

    Array(retired_ddocs).each do |ddoc|
      next unless existing_ddocs.include?(ddoc.to_s)

      pruned += 1 if delete_design_doc(db_url, ddoc.to_s, logger:, label:)
    end

    logger&.info("#{label}: pruned #{pruned} retired index design doc(s)") if pruned.positive?
    pruned
  end

  def delete_design_doc(db_url, ddoc, logger:, label:)
    doc_url = "#{db_url}/_design/#{ddoc}"
    rev = JSON.parse(RestClient.get(doc_url, accept: :json).body)['_rev']
    RestClient.delete("#{doc_url}?rev=#{rev}")
    logger&.info("#{label}: deleted retired index design doc _design/#{ddoc}")
    true
  rescue RestClient::NotFound
    false
  rescue StandardError => e
    logger&.warn("#{label}: could not delete retired index design doc _design/#{ddoc}: #{e.class}: #{e.message}")
    false
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

  # A definition may name the design doc it should live in (:ddoc). Several
  # indexes sharing one design doc is the point: CouchDB updates every view in a
  # design doc in a single pass over the changes feed, so grouping N indexes into
  # one design doc turns N indexing passes per write into one. Definitions with no
  # :ddoc keep the historical one-design-doc-per-index behaviour.
  def create_index(db_url, definition, logger:, label:)
    ddoc = design_doc_for(definition)
    logger&.info("#{label}: creating missing CouchDB index #{definition[:name]} in _design/#{ddoc}")

    RestClient.post(
      "#{db_url}/_index",
      {
        type: 'json',
        name: definition[:name],
        ddoc: ddoc,
        index: { fields: definition[:fields] }
      }.to_json,
      { content_type: :json, accept: :json }
    )
  rescue StandardError => e
    logger&.warn("#{label}: could not create CouchDB index #{definition[:name]}: #{e.class}: #{e.message}")
  end

  def design_doc_for(definition)
    (definition[:ddoc].presence || definition[:name]).to_s
  end

  # Name, design doc AND fields must all match. The design doc is part of the
  # identity on purpose: an index sitting in the wrong design doc still has to be
  # recreated in the right one, which is exactly what migrating to grouped design
  # docs depends on. (This used to accept a name-only match, which would have
  # reported a consolidated index as already present and silently skipped the
  # migration.) Definitions without :ddoc expect ddoc == name, so callers that
  # never grouped their indexes are unaffected.
  def index_matches_definition?(index, definition)
    return false unless index['type'].to_s == 'json'

    index['name'].to_s == definition[:name].to_s &&
      normalize_ddoc(index['ddoc']) == design_doc_for(definition) &&
      fields_for(index) == definition[:fields].map(&:to_s)
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
