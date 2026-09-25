# frozen_string_literal: true

require 'mysql2'

# Backfills obs.obs_group_id for observations that were migrated from a
# facility's original EMR database (via bin/emr_to_mahis_migrator.rb) but
# never got their obs_group_id resolved — see the update_group_obs_ids step
# in that script. That step assumes the source database is reachable on the
# SAME MySQL connection (a same-server JOIN); the original per-facility
# databases actually live on a separate host, so this task resolves the
# parent/child link via a second connection to that source instead.
#
# Symptom this fixes: Lab::LabOrderSerializer.serialize_order returns
# "result" => nil for a test even though the underlying observation exists
# with a real value — because the child "measure" observation's obs_group_id
# doesn't point back at its parent "Lab test result" observation.
#
# Scoped to lab orders only: the obs table has ~54M rows total, and most of
# them (~27M) have obs_group_id IS NULL as their NORMAL, correct state
# (standalone observations that were never grouped) — that predicate alone is
# not "broken", so it is not a usable scan key on its own. What we actually
# care about lives under lab orders specifically, identified via
# Lab::LabOrder's own default_scope (~208k of the 3.2M rows in orders).
# So pagination drives off the SMALL, PK-indexed orders table first, then
# looks up each batch's obs via the obs_order index — never a full obs scan.
# (A naive `obs JOIN orders` with obs_group_id IS NULL in the WHERE clause
# lets MySQL choose to drive off obs's own obs_group_id index instead, which
# EXPLAIN showed hitting ~27M rows before the join — this is exactly the
# query shape that must be avoided.)
#
# The central database aggregates MANY facilities, each with its own original
# source database — SOURCE_DB_* only ever points at one of them. Without
# LOCATION_ID, a sweep resolves orders belonging to that one facility fine and
# reports every other facility's orders as "not in source" — which is
# harmless but wasted work, and can be a lot of it: one 2000-order batch from
# an unrelated facility was found to carry three orders with ~71,000
# observations EACH (a data-quality outlier, not real lab data), which alone
# dominated that batch's remote query and bulk UPDATE. Passing LOCATION_ID
# scopes pagination to one facility's orders up front via their encounter, so
# neither the wasted lookups nor that facility's outliers are ever pulled in.
#
# Usage (scoped to one order — verified against XA18262224):
#   SOURCE_DB_HOST=127.0.0.1 SOURCE_DB_USER=dev SOURCE_DB_PASSWORD=*** \
#     bin/rails "lab:repair_obs_group_ids[XA18262224]"
#
# Usage (sweeps every ungrouped observation under one facility's lab orders —
# LOCATION_ID must match the facility SOURCE_DB_* is the true source for):
#   SOURCE_DB_HOST=127.0.0.1 SOURCE_DB_USER=dev SOURCE_DB_PASSWORD=*** \
#     LOCATION_ID=32 bin/rails lab:repair_obs_group_ids
#
# Env vars:
#   SOURCE_DB_HOST, SOURCE_DB_USER, SOURCE_DB_PASSWORD  — required
#   SOURCE_DB_NAME    — default: openmrs_prod
#   SOURCE_DB_PORT    — default: 3306
#   LOCATION_ID       — scope the sweep to one facility (via its encounters);
#                       strongly recommended whenever no accession is given
#   ORDER_BATCH_SIZE   — lab orders paginated per round trip (default 2000;
#                        each order carries roughly 4-12 obs, so this is the
#                        real lever on remote-query and batch-UPDATE size)
#   SOURCE_DB_TIMEOUT  — seconds before a single remote query aborts instead
#                        of hanging indefinitely (default 30)
#   SOURCE_DB_CHUNK_SIZE — ids per remote query (default 1000); keeps each
#                        round trip small regardless of ORDER_BATCH_SIZE
#   VERBOSE=true       — log every remote chunk's timing, not just slow ones
#   DRY_RUN=true       — report what would change, write nothing
#
# Scales to millions of rows:
#   - Reads are keyset-paginated over orders.order_id (WHERE order_id >
#     last_id ORDER BY order_id LIMIT ORDER_BATCH_SIZE), never a single
#     upfront pluck of the whole orphan set — memory stays bounded to one
#     batch's obs regardless of total row count.
#   - Writes go through a per-connection TEMPORARY TABLE bulk-loaded with one
#     multi-row INSERT, then applied with a single `UPDATE obs JOIN tmp ...`
#     per batch — one round trip for up to a batch's worth of rows, instead
#     of one UPDATE per row. Same pattern build_migration_id_maps /
#     migrate_obs_via_sql already use elsewhere in the migrator.
#   - Session timeouts are extended up front, same as prepare_centralized_db,
#     since a full sweep can run far longer than MySQL's default wait_timeout.
#
# Safe to re-run / crash-resumable: only ever touches local rows where
# obs_group_id IS NULL, so an observation already resolved (by this task, by
# update_group_obs_ids, or by hand) is never revisited, and a run that's
# killed partway just picks back up from the lowest remaining order_id.

# Decides, for one batch of ungrouped local observations, which can be repaired and
# which must be skipped (and why), given what's already been looked up locally and from
# the source DB. Kept free of any DB/network IO so it's unit-testable without a real or
# mocked MySQL connection on either side.
class ObsGroupIdBatchResolution
  attr_reader :resolved, :skipped_not_in_source, :skipped_source_also_ungrouped, :skipped_parent_not_migrated

  def initialize(obs_batch:, source_group_by_uuid:, parent_uuid_by_source_id:, target_parent_id_by_uuid:)
    @resolved = []
    @skipped_not_in_source = 0
    @skipped_source_also_ungrouped = 0
    @skipped_parent_not_migrated = 0

    obs_batch.each do |(obs_id, uuid)|
      unless source_group_by_uuid.key?(uuid)
        @skipped_not_in_source += 1
        next
      end

      src_group_id = source_group_by_uuid[uuid]
      if src_group_id.nil?
        @skipped_source_also_ungrouped += 1
        next
      end

      parent_uuid = parent_uuid_by_source_id[src_group_id]
      target_parent_id = parent_uuid && target_parent_id_by_uuid[parent_uuid]
      unless target_parent_id
        @skipped_parent_not_migrated += 1
        next
      end

      @resolved << [obs_id, target_parent_id]
    end
  end
end

namespace :lab do
  desc 'Backfill obs_group_id (lab orders only) by resolving true parent/child linkage from the original facility database'
  task :repair_obs_group_ids, [:accession_number] => :environment do |_t, args|
    host     = ENV['SOURCE_DB_HOST']
    user     = ENV['SOURCE_DB_USER']
    password = ENV['SOURCE_DB_PASSWORD']
    database = ENV['SOURCE_DB_NAME'] || 'openmrs_prod'
    port     = (ENV['SOURCE_DB_PORT'] || 3306).to_i
    order_batch_size = (ENV['ORDER_BATCH_SIZE'] || 2000).to_i
    location_id = ENV['LOCATION_ID'].presence&.to_i
    dry_run  = ENV['DRY_RUN'] == 'true'

    abort('✗ SOURCE_DB_HOST is required') if host.blank?
    abort('✗ SOURCE_DB_USER is required') if user.blank?
    abort('✗ SOURCE_DB_PASSWORD is required') if password.blank?

    remote_timeout = (ENV['SOURCE_DB_TIMEOUT'] || 30).to_i
    remote_chunk_size = (ENV['SOURCE_DB_CHUNK_SIZE'] || 1000).to_i
    # A stuck remote query previously hung indefinitely with no feedback —
    # these bound every socket op so a genuinely stuck query raises within
    # remote_timeout seconds instead of hanging forever with no way to tell
    # it apart from "just slow". Chunking below (remote_chunk_size) is what
    # actually keeps each individual query small enough to stay fast.
    source = Mysql2::Client.new(host:, username: user, password:, database:, port:,
                                 connect_timeout: 10, read_timeout: remote_timeout, write_timeout: remote_timeout)
    puts "✓ Connected to source #{database}@#{host}:#{port} (remote query timeout #{remote_timeout}s, chunk size #{remote_chunk_size})"

    # Runs `sql_for.(chunk)` once per remote_chunk_size-sized slice of `ids`
    # instead of one big query, logging size + timing per chunk so a slow or
    # stuck remote call is immediately visible (which query, how big) rather
    # than a silent hang.
    remote_query_chunked = lambda do |label, ids, &sql_for|
      ids.each_slice(remote_chunk_size).flat_map do |chunk|
        t = Time.now
        result = source.query(sql_for.call(chunk)).to_a
        elapsed = (Time.now - t).round(2)
        puts "    ↳ #{label}: #{chunk.size} in, #{result.size} matched, #{elapsed}s" if elapsed > 2 || ENV['VERBOSE'] == 'true'
        result
      end
    end

    conn = ActiveRecord::Base.connection
    begin
      conn.execute('SET SESSION net_read_timeout=3600, net_write_timeout=3600, wait_timeout=28800, interactive_timeout=28800')
    rescue StandardError => e
      puts "⚠ Could not extend MySQL session timeouts: #{e.message}"
    end

    single_order_id = nil
    if args[:accession_number]
      order = Lab::LabOrder.unscoped.find_by(accession_number: args[:accession_number])
      abort("✗ No order found for accession #{args[:accession_number]}") unless order

      single_order_id = order.order_id
      puts "Scoped to order ##{order.order_id} (#{args[:accession_number]})"
    elsif location_id
      puts "Scoped to location_id #{location_id} — matches the single source facility SOURCE_DB_* points at"
    else
      puts '⚠ No accession or LOCATION_ID given — sweeping every lab order across every facility.'
      puts '  This only correctly resolves orders whose true source is SOURCE_DB_* — everything from'
      puts '  other facilities will report as "not in source". Prefer LOCATION_ID=<id> for one facility at a time.'
    end

    total_orders =
      if single_order_id
        1
      elsif location_id
        Lab::LabOrder.joins(:encounter).where(encounter: { location_id: }).count
      else
        Lab::LabOrder.count
      end
    puts "Total lab orders in scope: #{total_orders}"

    unless dry_run
      conn.execute(<<~SQL)
        CREATE TEMPORARY TABLE tmp_obs_group_fix (
          obs_id INT NOT NULL PRIMARY KEY,
          obs_group_id INT NOT NULL
        ) ENGINE=InnoDB
      SQL
    end

    fixed = 0
    scanned = 0
    orders_seen = 0
    skipped_not_in_source = 0
    skipped_source_also_ungrouped = 0
    skipped_parent_not_migrated = 0
    last_order_id = 0
    start_time = Time.now

    loop do
      order_ids =
        if single_order_id
          break if orders_seen.positive?

          [single_order_id]
        else
          # Lab::LabOrder's default_scope is the authoritative definition of "is
          # this a lab order" (order_type join + concept exclusion) — more
          # correct than proxying on orders.accession_number IS NOT NULL.
          # orders has no location_id of its own — go through its encounter.
          # LOCATION_ID also sidesteps whatever facility a given order really
          # belongs to not matching SOURCE_DB_*, and any facility-specific data
          # quality outliers (e.g. a handful of orders with tens of thousands
          # of stray observations attached) living outside the scoped facility.
          relation = Lab::LabOrder.order(:order_id).where('orders.order_id > ?', last_order_id)
          relation = relation.joins(:encounter).where(encounter: { location_id: }) if location_id
          batch = relation.limit(order_batch_size).pluck(:order_id)
          break if batch.empty?

          last_order_id = batch.last
          batch
        end
      orders_seen += order_ids.size

      obs_batch = Observation.unscoped.where(order_id: order_ids, obs_group_id: nil).pluck(:obs_id, :uuid)
      next if obs_batch.empty?

      scanned += obs_batch.size

      uuids = obs_batch.map(&:last)
      rows = remote_query_chunked.call('uuid resolve', uuids) do |chunk|
        escaped = chunk.map { |u| source.escape(u) }
        "SELECT uuid, obs_group_id FROM obs WHERE uuid IN ('#{escaped.join("','")}')"
      end
      source_group_by_uuid = rows.each_with_object({}) { |r, h| h[r['uuid']] = r['obs_group_id'] }

      parent_source_ids = source_group_by_uuid.values.compact.uniq
      parent_uuid_by_source_id = {}
      unless parent_source_ids.empty?
        parent_rows = remote_query_chunked.call('parent resolve', parent_source_ids) do |chunk|
          "SELECT obs_id, uuid FROM obs WHERE obs_id IN (#{chunk.join(',')})"
        end
        parent_uuid_by_source_id = parent_rows.each_with_object({}) { |r, h| h[r['obs_id']] = r['uuid'] }
      end

      target_parent_id_by_uuid = Observation.unscoped
                                             .where(uuid: parent_uuid_by_source_id.values.compact.uniq)
                                             .pluck(:uuid, :obs_id).to_h

      batch_resolution = ObsGroupIdBatchResolution.new(
        obs_batch:, source_group_by_uuid:, parent_uuid_by_source_id:, target_parent_id_by_uuid:
      )
      resolved = batch_resolution.resolved
      skipped_not_in_source += batch_resolution.skipped_not_in_source
      skipped_source_also_ungrouped += batch_resolution.skipped_source_also_ungrouped
      skipped_parent_not_migrated += batch_resolution.skipped_parent_not_migrated

      if resolved.any?
        if dry_run
          resolved.first(10).each { |obs_id, group_id| puts "  would set obs_id=#{obs_id} obs_group_id=#{group_id}" }
          puts "  ... (#{resolved.size} more in this batch)" if resolved.size > 10
        else
          conn.execute('TRUNCATE TABLE tmp_obs_group_fix')
          values = resolved.map { |obs_id, group_id| "(#{obs_id.to_i}, #{group_id.to_i})" }.join(',')
          conn.execute("INSERT INTO tmp_obs_group_fix (obs_id, obs_group_id) VALUES #{values}")
          conn.execute(<<~SQL)
            UPDATE obs o
            JOIN tmp_obs_group_fix t ON t.obs_id = o.obs_id
            SET o.obs_group_id = t.obs_group_id
          SQL
        end
        fixed += resolved.size
      end

      elapsed = (Time.now - start_time).round(1)
      rate = (orders_seen / [elapsed, 0.1].max).round(0)
      pct = total_orders.positive? ? ((orders_seen.to_f / total_orders) * 100).round(1) : 100.0
      remaining = [total_orders - orders_seen, 0].max
      puts "  #{orders_seen}/#{total_orders} order(s) scanned (#{pct}%, #{remaining} remaining, order_id > #{last_order_id}), " \
           "#{scanned} obs checked, #{fixed} fixed so far, #{rate} orders/s"
    end

    conn.execute('DROP TEMPORARY TABLE IF EXISTS tmp_obs_group_fix') unless dry_run
    source.close

    puts "\n#{dry_run ? 'Would repair' : 'Repaired'} #{fixed} of #{scanned} checked observation(s) across #{orders_seen}/#{total_orders} order(s) (100.0%) in #{(Time.now - start_time).round(1)}s"
    puts "Skipped — uuid not found in source: #{skipped_not_in_source}" if skipped_not_in_source.positive?
    puts "Skipped — source obs_group_id is NULL too: #{skipped_source_also_ungrouped}" if skipped_source_also_ungrouped.positive?
    puts "Skipped — parent not migrated to central DB yet: #{skipped_parent_not_migrated}" if skipped_parent_not_migrated.positive?
  end
end
