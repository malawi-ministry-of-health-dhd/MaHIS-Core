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
    LIST_VIEW = 'patient_list'

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
            },
            # Ordered, paginatable patient lists per [location, category]. Static
            # categories are ordered by last visit date; defaulters are keyed by
            # last dispensation date so a date-range query selects the window.
            LIST_VIEW => {
              map: <<~JAVASCRIPT,
                function(doc) {
                  if (!doc.ncd_active || !doc.ncd_location_id) { return; }
                  var loc = String(doc.ncd_location_id);
                  var lv = doc.ncd_last_visit_date || "0000-00-00";
                  var g = doc.ncd_gender || "";
                  function emitCat(cat, sortVal) {
                    emit([loc, cat, sortVal], null);
                    if (g) { emit([loc, cat + "|" + g, sortVal], null); }
                  }
                  emitCat("active", lv);
                  if (doc.ncd_has_complications === true) { emitCat("complications", lv); }
                  if (doc.ncd_has_pending_dispensation === true) { emitCat("pending_dispensations", lv); }
                  if (doc.ncd_pending_id === true) { emitCat("pending_ids", lv); }
                  if (doc.ncd_last_dispensation_date) { emitCat("defaulters", doc.ncd_last_dispensation_date); }
                }
              JAVASCRIPT
              reduce: '_count'
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

      # Ordered, paginated patient list for a [location, category] via the
      # patient_list view. Returns { count:, docs: } reading only the requested
      # page (count comes from the view's reduce, not a full scan).
      def list_by_category(location_id:, category:, offset:, limit:, gender: nil)
        loc = location_id.to_s
        category = category.to_s.presence || 'active'
        # gender folds into the category key via the composite [loc, "cat|G"] emits.
        key_cat = gender.present? ? "#{category}|#{gender.to_s.strip.upcase}" : category

        if category == 'defaulters'
          start_key = [loc, key_cat, (Date.current - 120).to_s]
          end_key = [loc, key_cat, (Date.current - 60).to_s]
          count = view_count(startkey: start_key, endkey: end_key)
          rows = view(LIST_VIEW, reduce: false, include_docs: true, skip: offset, limit: limit,
                              startkey: start_key.to_json, endkey: end_key.to_json).fetch('rows', [])
        else
          count = view_count(startkey: [loc, key_cat], endkey: [loc, key_cat, {}])
          # descending so most-recent visit comes first
          rows = view(LIST_VIEW, reduce: false, include_docs: true, descending: true, skip: offset, limit: limit,
                              startkey: [loc, key_cat, {}].to_json, endkey: [loc, key_cat].to_json).fetch('rows', [])
        end

        { count: count, docs: rows.filter_map { |row| row['doc'] } }
      end

      def view_count(startkey:, endkey:)
        view(LIST_VIEW, reduce: true, group: false, startkey: startkey.to_json, endkey: endkey.to_json)
          .fetch('rows', []).first&.fetch('value', 0).to_i
      end

      # Fetch full projection documents for the given patient ids, preserving id
      # order (CouchDB _all_docs returns rows in key order).
      def fetch_by_ids(ids)
        # _id values are always strings; patientID may be stored as an integer,
        # so coerce to match or _all_docs returns no docs.
        ids = Array(ids).compact.map(&:to_s)
        return [] if ids.empty?

        response = RestClient.post(
          db_url('_all_docs?include_docs=true'),
          { keys: ids }.to_json,
          { content_type: :json, accept: :json }
        )
        JSON.parse(response.body).fetch('rows', []).filter_map { |row| row['doc'] }
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
