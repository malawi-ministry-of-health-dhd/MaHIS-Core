# frozen_string_literal: true

# Person names were saved as ward/department locations ("nikisoni majawira",
# "Kamanka"). They render in every department and ward picker at the facility
# they were created under -- a global department shows everywhere -- and there is
# no UI to remove them.
#
# Rows are retired rather than deleted: that is how the app removes locations
# everywhere else (Location < RetirableRecord, whose default scope filters
# retired: 0), it keeps the audit trail, and it is reversible.
#
# Anything hanging off an invalidly named location is retired with it, because a
# department cannot go without taking its wards: retiring it alone would leave
# them classified against a retired row. Children are collected two ways, since
# the model changed mid-life (see 20260808000000_consolidate_global_departments):
#   * wards recording the department in a 'Department' location attribute
#   * legacy child locations still hanging off it via parent_location
# Collection recurses, so a ward's own children come too.
#
# The one thing that stops a group being retired is real clinical data. Every
# location-bearing column is counted for every member first, and a group with any
# encounters, beds, visits or the like is left alone and reported instead --
# retiring those would hide records rather than clean them up.
#
# Matching is exact after case-folding and trimming, so a genuine location that
# merely contains one of these words is never touched.
class RetireInvalidWardDepartmentNames < ActiveRecord::Migration[8.1]
  REQUIRED_TABLES = %i[location].freeze
  RETIRE_REASON = 'Invalid location name (person name entered in error); unreferenced'
  DEPENDENT_REASON = 'Retired with invalidly named parent location %<parent_id>s'
  DEPENDENT_REASON_PREFIX = 'Retired with invalidly named parent location '

  # Exact names to retire, lower-cased and trimmed. 'nikisoni majaira' is the
  # misspelling the first one was reported under; the stored value is 'majawira'.
  # Only the offending locations are listed -- their wards and children are found
  # automatically, so nothing that merely hangs off one needs naming here.
  INVALID_NAMES = [
    'nikisoni majawira',
    'nikisoni majaira',
    'kamanka'
  ].freeze

  # Guards against a cycle in parent_location, which would otherwise recurse
  # forever while collecting children.
  MAX_DEPTH = 10

  # Every column that can point at a location, counted before retiring anything.
  # Pairs absent from a given installation are skipped.
  LOCATION_REFERENCES = [
    %w[encounter location_id],
    %w[obs location_id],
    %w[visit location_id],
    %w[visits location_id],
    %w[patient_program location_id],
    %w[patient_identifier location_id],
    %w[clinic_registration_encounter location_id],
    %w[ever_registered_obs location_id],
    %w[bed_mgmt_bed location_id],
    %w[users location_id],
    %w[stages location_id],
    %w[session_schedules location_id],
    %w[pharmacy_batches location_id],
    %w[pharmacy_batch_item_reallocations location_id],
    %w[program_location_restriction location_id],
    %w[reporting_report_design location_id],
    %w[immunization_cache_data location_id],
    %w[global_property location_id],
    %w[location parent_location]
  ].freeze

  def up
    return say('Skipped: location table is not present.') unless REQUIRED_TABLES.all? { |table| table_exists?(table) }

    named = invalid_locations
    return say('Nothing to do: no invalidly named locations found.') if named.empty?

    groups = named.map { |location| build_group(location) }

    # References between rows this migration is retiring are discounted, so a
    # ward classified against a junk department does not block it.
    in_scope = groups.flat_map { |group| group[:member_ids] }.uniq

    retired = 0
    skipped = 0

    groups.each do |group|
      blockers = group_blockers(group, in_scope)

      if blockers.any?
        skipped += 1
        say("Left ##{group[:root_id]} '#{group[:root_name]}' alone: #{blockers.join(', ')}.", true)
        next
      end

      retired += retire_group(group)
    end

    say("Done: #{retired} location(s) retired, #{skipped} group(s) left for manual review.")
  end

  # Only rows this migration retired are restored, identified by the reasons it
  # writes. Locations retired for any other purpose are untouched.
  def down
    return say('Skipped: location table is not present.') unless table_exists?(:location)

    run_sql(<<~SQL.squish)
      UPDATE location
      SET retired = 0,
          retired_by = NULL,
          date_retired = NULL,
          retire_reason = NULL,
          date_changed = #{quote(Time.now)}
      WHERE retired = 1
        AND (retire_reason = #{quote(RETIRE_REASON)}
             OR retire_reason LIKE #{quote("#{DEPENDENT_REASON_PREFIX}%")})
    SQL

    say('Restored locations retired by this migration.')
  end

  private

  # A group is one invalidly named location plus everything hanging off it.
  # dependent_ids are ordered deepest-first so children are retired before the
  # rows they hang off.
  def build_group(location)
    root_id = location['location_id']
    dependent_ids = collect_dependents(root_id)

    {
      root_id: root_id,
      root_name: location['name'],
      dependent_ids: dependent_ids,
      member_ids: [root_id] + dependent_ids
    }
  end

  def collect_dependents(root_id, depth = 0, seen = [])
    return [] if depth >= MAX_DEPTH

    direct = (ward_ids_classified_against(root_id) + child_location_ids(root_id)).uniq
    direct -= seen + [root_id]
    return [] if direct.empty?

    seen += direct
    # Depth-first, deepest rows first, so retiring proceeds bottom-up.
    direct.flat_map { |id| collect_dependents(id, depth + 1, seen) } + direct
  end

  # Wards record their department as a 'Department' location attribute holding
  # the department's location_id as a string, so this compares as text.
  def ward_ids_classified_against(location_id)
    return [] unless table_exists?(:location_attribute)

    select_all(<<~SQL.squish).rows.flatten
      SELECT DISTINCT la.location_id
      FROM location_attribute la
      JOIN location l ON l.location_id = la.location_id
      WHERE la.voided = 0
        AND l.retired = 0
        AND TRIM(la.value_reference) = #{quote(location_id.to_s)}
    SQL
  end

  def child_location_ids(location_id)
    select_all(<<~SQL.squish).rows.flatten
      SELECT location_id FROM location
      WHERE retired = 0 AND parent_location = #{quote(location_id)}
    SQL
  end

  # Describes any clinical data attached to a group, e.g.
  # "#38116 'haffa' is referenced by encounter.location_id (3)". Empty means the
  # whole group is safe to retire.
  def group_blockers(group, in_scope)
    group[:member_ids].flat_map do |id|
      references = references_for(id, ignore_location_ids: in_scope)
      next [] if references.empty?

      label = id == group[:root_id] ? "##{id}" : "dependent ##{id}"
      ["#{label} is referenced by #{references.join(', ')}"]
    end
  end

  def references_for(location_id, ignore_location_ids: [])
    ignored = ignore_location_ids - [location_id]

    LOCATION_REFERENCES.filter_map do |table, column|
      next unless table_exists?(table) && column_exists?(table, column)

      # For the location table itself the row's own key identifies the referrer,
      # so a child that is also being retired can be discounted.
      exclusion = table == 'location' ? not_in_clause('location_id', ignored) : ''

      count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*) FROM #{table} WHERE #{column} = #{quote(location_id)}#{exclusion}
      SQL
      next if count.zero?

      "#{table}.#{column} (#{count})"
    end + ward_department_references(location_id, ignored)
  end

  def ward_department_references(location_id, ignored = [])
    return [] unless table_exists?(:location_attribute)

    count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM location_attribute
      WHERE voided = 0
        AND TRIM(value_reference) = #{quote(location_id.to_s)}#{not_in_clause('location_id', ignored)}
    SQL
    return [] if count.zero?

    ["location_attribute.value_reference (#{count})"]
  end

  def retire_group(group)
    count = 0

    group[:dependent_ids].each do |id|
      next unless retire_location(id, format(DEPENDENT_REASON, parent_id: group[:root_id]))

      count += 1
      say("Retired dependent ##{id} of ##{group[:root_id]}.", true)
    end

    if retire_location(group[:root_id], RETIRE_REASON)
      count += 1
      say("Retired ##{group[:root_id]} '#{group[:root_name]}'.", true)
    end

    count
  end

  def retire_location(location_id, reason)
    run_sql(<<~SQL.squish)
      UPDATE location
      SET retired = 1,
          date_retired = #{quote(Time.now)},
          retire_reason = #{quote(reason)},
          date_changed = #{quote(Time.now)}
      WHERE location_id = #{quote(location_id)}
        AND retired = 0
    SQL

    true
  end

  def invalid_locations
    select_all(<<~SQL.squish).to_a
      SELECT location_id, name
      FROM location
      WHERE retired = 0
        AND LOWER(TRIM(name)) IN (#{quoted_invalid_names})
      ORDER BY location_id
    SQL
  end

  def quoted_invalid_names
    INVALID_NAMES.map { |name| quote(name) }.join(', ')
  end

  def not_in_clause(column, ids)
    return '' if ids.empty?

    " AND #{column} NOT IN (#{ids.map { |id| quote(id) }.join(', ')})"
  end

  # Named `db` rather than `connection`: ActiveRecord::Migration relies on its
  # own connection accessor, and shadowing it sends every call through
  # method_missing instead (which silently no-ops the statements).
  def db
    ActiveRecord::Base.connection
  end

  def quote(value)
    db.quote(value)
  end

  def select_value(sql)
    db.select_value(sql)
  end

  def select_all(sql)
    db.select_all(sql)
  end

  def run_sql(sql)
    db.execute(sql)
  end
end
