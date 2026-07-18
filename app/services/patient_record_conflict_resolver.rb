# frozen_string_literal: true

require 'set'
require 'digest'

# Server-side, merge-aware resolver for CouchDB `patients_records` conflicts.
#
# Conflicts are inherent to the offline-first model: the same doc `_id` is edited
# both on an offline replica and on the server, and replication stores both
# branches. CouchDB deterministically picks a structural winner (highest
# generation, then rev hash) and keeps the loser(s) as `_conflicts`. Today the
# only resolver runs on the frontend, timestamp-wins, and only when a user opens
# the sync-badge UI (MAHIS/src/stores/SyncBadgeStore.ts), so conflicts accumulate.
#
# This mirrors that frontend resolution but runs on the backend AND — because
# this is patient clinical data — is MERGE-AWARE rather than pick-winner: it
# never drops a clinical record (observation, order, identifier, ...) that exists
# only in a losing branch. The chosen "winner" (latest by timestamp, then
# generation — the same rule the frontend uses) provides the base content and
# scalar/identity fields; loser-only records are unioned in by their stable ids.
#
# Dry-run by default: `resolve`/`sweep` only report what they WOULD do. Pass
# `dry_run: false` (or APPLY=1 to the rake task) to actually PUT the merged doc
# on the structural-winner revision and tombstone the losing revisions.
class PatientRecordConflictResolver
  include CouchdbSync

  PATIENTS_DB = 'patients_records'

  # Re-read/re-merge/re-apply attempts when a concurrent writer advances the
  # winning revision (409) between our read and write.
  MAX_APPLY_ATTEMPTS = 3

  # Winner-selection timestamp fields, in priority order. Mirrors
  # CONFLICT_RESOLUTION_TIMESTAMP_FIELDS in SyncBadgeStore.ts so the backend and
  # frontend agree on which revision's content wins.
  TIMESTAMP_FIELDS = %w[
    updated_at updatedAt date_updated dateUpdated modified_at modifiedAt
    last_modified lastModified created_at createdAt date_created dateCreated
    encounter_datetime encounterDatetime
  ].freeze

  # Stable identity keys used to union clinical records across branches, in
  # priority order. A record with none of these falls back to a content hash.
  IDENTITY_KEYS = %w[
    obs_id order_id patient_identifier_id appointment_id relationship_id
    program_id id uuid
  ].freeze

  # Hash-of-arrays clinical collections (each value is a hash whose array members
  # — saved/unsaved/results/voided/orders/obs — are unioned member-by-member).
  HASH_COLLECTIONS = %w[
    MedicationOrder labOrders vaccineAdministration appointments
    guardianInformation nextOfKinInformation
  ].freeze

  # Top-level array collections unioned directly.
  ARRAY_COLLECTIONS = %w[patient_identifiers activePrograms].freeze

  Result = Struct.new(
    :id, :winner_rev, :winner_src_rev, :loser_revs, :additions, :applied,
    keyword_init: true
  ) do
    def conflicted?
      Array(loser_revs).any?
    end

    def total_additions
      additions.to_h.values.sum
    end
  end

  def initialize(dry_run: true, logger: Rails.logger)
    @dry_run = dry_run
    @logger = logger
  end

  # Resolve a single document by id. Returns a Result, or nil if the doc is
  # missing. A doc with no `_conflicts` yields a Result with empty loser_revs
  # (conflicted? == false) and no changes.
  #
  # Another writer (the listener, the online REST path, RebuildPatientLabDataJob)
  # can advance the winning revision between our read and write, yielding a 409.
  # The merged content depends on the current branches, so we re-read, re-merge
  # and re-apply from scratch rather than retry a stale PUT.
  def resolve(doc_id, attempt = 1)
    winning = fetch_with_conflicts(doc_id)
    return nil unless winning

    loser_revs = Array(winning['_conflicts'])
    if loser_revs.empty?
      return Result.new(id: doc_id, winner_rev: winning['_rev'], winner_src_rev: winning['_rev'],
                        loser_revs: [], additions: {}, applied: false)
    end

    branches = [winning] + loser_revs.map { |rev| fetch_rev(doc_id, rev) }.compact
    base_src = choose_winner(branches)

    base = base_src.deep_dup
    base['_rev'] = winning['_rev'] # write onto CouchDB's structural-winner revision
    reset_conflict_metadata!(base)

    additions = Hash.new(0)
    branches.reject { |b| b.equal?(base_src) }.each { |other| merge_branch!(base, other, additions) }

    apply!(doc_id, base, loser_revs) unless @dry_run

    Result.new(
      id: doc_id, winner_rev: winning['_rev'], winner_src_rev: base_src['_rev'],
      loser_revs: loser_revs, additions: additions, applied: !@dry_run
    )
  rescue RestClient::Conflict, RestClient::PreconditionFailed => e
    raise if @dry_run || attempt >= MAX_APPLY_ATTEMPTS

    @logger.warn("[ConflictResolver] #{doc_id} changed under us (#{e.class}); " \
                 "re-resolving attempt #{attempt + 1}/#{MAX_APPLY_ATTEMPTS}")
    sleep(0.2 * attempt)
    resolve(doc_id, attempt + 1)
  end

  # Sweep every conflicted patient record. Yields each conflicted Result to the
  # block (if given) and returns the array of conflicted Results.
  #
  # Discovery is via `_changes?style=all_docs`, which lists every leaf revision
  # per doc WITHOUT loading doc bodies: a doc with more than one leaf is a
  # conflict candidate, so only those get a `resolve` call. This scales to the
  # full patients_records DB far better than scanning every doc body. `resolve`
  # re-reads `_conflicts` and is the source of truth (candidates whose extra
  # leaves are just tombstones are skipped).
  def sweep(page_size: 500)
    results = []
    since = 0

    loop do
      batch = changes_page(page_size, since)
      rows = Array(batch['results'])
      break if rows.empty?

      rows.each do |row|
        next if row['id'].to_s.start_with?('_design/')
        next unless Array(row['changes']).size > 1 # >1 leaf revision → conflict candidate

        begin
          result = resolve(row['id'])
        rescue StandardError => e
          # One doc that keeps changing under us (or otherwise fails) must not
          # abort the whole sweep — log it and move on.
          @logger.error("[ConflictResolver] Failed to resolve #{row['id']}: #{e.class}: #{e.message}")
          next
        end
        next unless result&.conflicted?

        results << result
        yield result if block_given?
      end

      next_since = batch['last_seq']
      break if next_since.nil? || next_since == since

      since = next_since
      break if rows.size < page_size
    end

    results
  end

  private

  # ── Winner selection (mirrors SyncBadgeStore.chooseLatestConflictDocument) ──

  def choose_winner(branches)
    branches.max_by { |doc| [document_timestamp(doc), revision_generation(doc['_rev'])] }
  end

  def document_timestamp(doc)
    TIMESTAMP_FIELDS.each do |field|
      value = doc[field]
      next if value.nil? || value == ''
      return value.to_f if value.is_a?(Numeric)

      parsed = (Time.parse(value.to_s) rescue nil)
      return parsed.to_f if parsed
    end
    0.0
  end

  def revision_generation(rev)
    rev.to_s.split('-').first.to_i
  end

  # ── Merge (additive union of loser-only clinical records onto the winner) ──

  def merge_branch!(base, other, additions)
    merged, added = merge_observations(base['observations'], other['observations'])
    base['observations'] = merged
    additions[:observations] += added

    HASH_COLLECTIONS.each do |key|
      next unless other[key].is_a?(Hash)

      base[key] = {} unless base[key].is_a?(Hash)
      _, added = merge_hash_collection(base[key], other[key])
      additions[key.to_sym] += added
    end

    ARRAY_COLLECTIONS.each do |key|
      next unless other[key].is_a?(Array)

      merged, added = union_records(base[key], other[key])
      base[key] = merged
      additions[key.to_sym] += added
    end

    if other['visits'].is_a?(Hash)
      base['visits'] = {} unless base['visits'].is_a?(Hash)
      additions[:visits] += merge_scalar_date_lists!(base['visits'], other['visits'])
    end
  end

  # Observations are an array of per-encounter groups, each with an `obs` list
  # whose entries (and their nested `children`) carry obs_id. We add only obs
  # whose obs_id appears nowhere in the winner — existing obs (and their whole
  # subtree) are kept as the winner has them; we never merge inside an obs.
  def merge_observations(base, other)
    base = Array(base).dup
    other = Array(other)
    return [base, 0] if other.empty?

    known_obs_ids = collect_obs_ids(base)
    groups_by_key = {}
    base.each { |group| groups_by_key[observation_group_key(group)] = group }

    added = 0
    other.each do |group|
      new_obs = Array(group['obs']).reject { |obs| known_obs_ids.include?(observation_id(obs)) }
      next if new_obs.empty?

      added += new_obs.size
      new_obs.each { |obs| gather_obs_ids(obs, known_obs_ids) } # guard against dup adds across branches

      key = observation_group_key(group)
      if (target = groups_by_key[key])
        target['obs'] = Array(target['obs']) + new_obs
      else
        new_group = group.deep_dup
        new_group['obs'] = new_obs
        base << new_group
        groups_by_key[key] = new_group
      end
    end

    [base, added]
  end

  def observation_group_key(group)
    [group['encounter_type'], group['visit_id']]
  end

  def observation_id(obs)
    obs.is_a?(Hash) ? (obs['obs_id'] || obs['obs_id'.to_sym]) : nil
  end

  def collect_obs_ids(groups)
    ids = Set.new
    Array(groups).each { |group| Array(group['obs']).each { |obs| gather_obs_ids(obs, ids) } }
    ids
  end

  def gather_obs_ids(obs, ids)
    return unless obs.is_a?(Hash)

    oid = obs['obs_id']
    ids << oid unless oid.nil?
    Array(obs['children']).each { |child| gather_obs_ids(child, ids) }
  end

  # Union each array-valued member of a hash-of-arrays collection; scalar members
  # (e.g. nextOfKinInformation.relationshipID) keep the winner's value.
  def merge_hash_collection(base, other)
    added = 0
    other.each do |key, value|
      next unless value.is_a?(Array)

      merged, count = union_records(base[key], value)
      base[key] = merged
      added += count
    end
    [base, added]
  end

  # Keep every base record; append other-branch records whose identity is not
  # already present. The winner therefore always wins on collisions.
  def union_records(base, other)
    base = Array(base).dup
    seen = base.map { |record| record_identity(record) }.to_set

    added = 0
    Array(other).each do |record|
      identity = record_identity(record)
      next if seen.include?(identity)

      seen << identity
      base << record
      added += 1
    end

    [base, added]
  end

  def record_identity(record)
    return "scalar:#{record.inspect}" unless record.is_a?(Hash)

    IDENTITY_KEYS.each do |key|
      value = record[key]
      return "#{key}:#{value}" unless value.nil? || value == ''
    end

    "hash:#{Digest::MD5.hexdigest(stable_json(record))}"
  end

  def stable_json(value)
    case value
    when Hash then value.sort_by { |k, _| k.to_s }.to_h { |k, v| [k, v] }.transform_values { |v| stable_json(v) }.to_json
    else value.to_json
    end
  end

  # visits carries parallel arrays of date strings; union them as sets.
  def merge_scalar_date_lists!(base, other)
    added = 0
    other.each do |key, value|
      next unless value.is_a?(Array)

      existing = Array(base[key])
      fresh = value - existing
      base[key] = existing + fresh
      added += fresh.size
    end
    added
  end

  # Mirrors SyncBadgeStore.buildResolvedConflictDocument.
  def reset_conflict_metadata!(doc)
    doc.delete('_conflicts')
    doc.delete('_revisions')
    doc.delete('_revs_info')
    doc.delete('_deleted')
    doc['has_conflicts'] = false
    doc['conflict_revisions'] = []
    doc['conflict_detected_at'] = nil
  end

  # ── CouchDB I/O (credentials embedded in COUCHDB_URL, as in CouchdbSync) ──

  def apply!(doc_id, doc, loser_revs)
    encoded_id = URI.encode_www_form_component(doc_id.to_s)
    RestClient.put(couchdb_url(PATIENTS_DB, encoded_id), doc.to_json, content_type: :json, accept: :json)

    loser_revs.each do |rev|
      RestClient.delete("#{couchdb_url(PATIENTS_DB, encoded_id)}?rev=#{rev}")
    rescue RestClient::NotFound
      # Already tombstoned by another resolver / the frontend — fine.
    end
  end

  def fetch_with_conflicts(doc_id)
    encoded_id = URI.encode_www_form_component(doc_id.to_s)
    response = RestClient.get("#{couchdb_url(PATIENTS_DB, encoded_id)}?conflicts=true", accept: :json)
    JSON.parse(response.body)
  rescue RestClient::NotFound
    nil
  end

  def fetch_rev(doc_id, rev)
    encoded_id = URI.encode_www_form_component(doc_id.to_s)
    response = RestClient.get("#{couchdb_url(PATIENTS_DB, encoded_id)}?rev=#{rev}", accept: :json)
    JSON.parse(response.body)
  rescue RestClient::NotFound
    nil
  end

  def changes_page(page_size, since)
    params = { 'style' => 'all_docs', 'limit' => page_size, 'since' => since }
    url = "#{couchdb_url(PATIENTS_DB)}/_changes?#{URI.encode_www_form(params)}"
    JSON.parse(RestClient.get(url, accept: :json).body)
  end
end
