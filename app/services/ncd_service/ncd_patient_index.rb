# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'cgi'

module NcdService
  # Dedicated CouchDB database holding one small summary document per NCD
  # patient ("projection"). This keeps the heavy patients_records documents
  # free of NCD dashboard fields while still allowing the dashboard to compute
  # results live via Mango queries / a reduce view over a compact index.
  #
  # A projection is produced by PatientRecordSearchFields.ncd_projection and is
  # keyed by the patient id, so writes are idempotent upserts.
  class NcdPatientIndex
    DB_NAME = 'ncd_patient_index'

    INDEXES = [
      { name: 'idx_ncd_location_active', fields: %w[ncd_location_id ncd_active] },
      { name: 'idx_ncd_location_pending_id', fields: %w[ncd_location_id ncd_active ncd_pending_id] },
      { name: 'idx_ncd_location_last_dispensation', fields: %w[ncd_location_id ncd_last_dispensation_date] }
    ].freeze

    STATS_DDOC = '_design/ncd_dashboard_stats'
    STATS_VIEW = 'stats'

    @index_cache = {}

    class << self
      def configured?
        CouchdbPatientService.couchdb_configured?
      end

      def db_url(*segments)
        CouchdbPatientService.couchdb_url(DB_NAME, *segments)
      end

      # Create the database, its Mango indexes and the reduce view. Idempotent.
      def ensure!
        ensure_db!
        ensure_indexes!
        ensure_views!
      end

      def ensure_db!
        CouchdbPatientService.ensure_db_exists(DB_NAME)
      end

      def ensure_indexes!(force: false)
        CouchdbIndexEnsurer.ensure!(
          db_url,
          INDEXES,
          cache: @index_cache,
          cache_key: db_url,
          logger: Rails.logger,
          force: force,
          label: 'NCD patient index'
        )
      end

      def ensure_views!
        desired = {
          _id: STATS_DDOC,
          language: 'javascript',
          views: {
            STATS_VIEW => {
              map: <<~JAVASCRIPT,
                function(doc) {
                  if (!doc.ncd_active || !doc.ncd_location_id) { return; }
                  var loc = String(doc.ncd_location_id);
                  emit([loc, "total"], 1);
                  if (doc.ncd_gender) { emit([loc, "gender", doc.ncd_gender], 1); }
                  if (doc.ncd_has_complications === true) { emit([loc, "complications"], 1); }
                  if (doc.ncd_has_pending_dispensation === true) { emit([loc, "pending_dispensation"], 1); }
                  if (doc.ncd_pending_id === true) { emit([loc, "pending_id"], 1); }
                  if (doc.ncd_last_dispensation_date) {
                    emit([loc, "last_dispensation", doc.ncd_last_dispensation_date], 1);
                  }
                }
              JAVASCRIPT
              reduce: '_sum'
            }
          }
        }

        current = begin
          JSON.parse(RestClient.get("#{db_url}/#{STATS_DDOC}").body)
        rescue RestClient::NotFound
          {}
        end

        desired[:_rev] = current['_rev'] if current['_rev'].present?
        return if current['views'] == JSON.parse(desired[:views].to_json)

        RestClient.put("#{db_url}/#{STATS_DDOC}", desired.to_json, { content_type: :json, accept: :json })
      end

      # Compute projections for the given patient records and bulk-upsert the
      # NCD patients. Non-NCD records are skipped (they yield no projection).
      # Returns the number of projections written.
      def upsert_records(records)
        projections = Array(records).filter_map { |record| PatientRecordSearchFields.ncd_projection(record) }
        upsert_projections(projections)
      end

      def upsert_projections(projections)
        projections = Array(projections).reject(&:blank?)
        return 0 if projections.empty?

        ensure_db!
        attach_existing_revs!(projections)

        RestClient.post(
          db_url('_bulk_docs'),
          { docs: projections }.to_json,
          { content_type: :json, accept: :json }
        )
        projections.length
      end

      # Remove a patient's projection (e.g. when they are no longer NCD-active).
      def delete(patient_id)
        return if patient_id.blank?

        doc = JSON.parse(RestClient.get(db_url(CGI.escape(patient_id.to_s))).body)
        RestClient.delete(db_url("#{CGI.escape(patient_id.to_s)}?rev=#{doc['_rev']}"))
        true
      rescue RestClient::NotFound
        false
      end

      def query(selector:, limit:, fields:, bookmark: nil, use_index: nil)
        body = { selector: selector, limit: limit, fields: fields }
        body[:bookmark] = bookmark if bookmark.present?
        body[:use_index] = use_index if use_index.present?

        response = RestClient.post(
          db_url('_find'),
          body.to_json,
          { content_type: :json, accept: :json }
        )
        JSON.parse(response.body)
      end

      def view(view_name, params = {})
        response = RestClient.get(
          db_url("#{STATS_DDOC}/_view/#{view_name}"),
          { accept: :json, params: params }
        )
        JSON.parse(response.body)
      end

      private

      # Look up current _rev for each projection id in one _all_docs call so the
      # bulk upsert updates existing docs instead of failing with a conflict.
      def attach_existing_revs!(projections)
        keys = projections.map { |projection| projection['_id'] }.compact
        return if keys.empty?

        response = RestClient.post(
          db_url('_all_docs'),
          { keys: keys }.to_json,
          { content_type: :json, accept: :json }
        )
        rows = JSON.parse(response.body).fetch('rows', [])

        rev_by_id = {}
        rows.each do |row|
          next if row['error']
          next if row.dig('value', 'deleted')

          rev_by_id[row['id']] = row.dig('value', 'rev')
        end

        projections.each do |projection|
          rev = rev_by_id[projection['_id']]
          projection['_rev'] = rev if rev.present?
        end
      end
    end
  end
end
