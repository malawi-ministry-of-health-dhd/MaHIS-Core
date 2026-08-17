# frozen_string_literal: true

# A person's name was saved as a ward/department location ("nikisoni majawira",
# created 2026-04-29). It renders in every department and ward picker at the
# facility it was created under, and there is no UI to remove it.
#
# The row carries no clinical data, so it is retired rather than deleted: that is
# how the app removes locations everywhere else (Location < RetirableRecord, whose
# default scope filters retired: 0), it keeps the audit trail, and it is
# reversible.
#
# Two safeguards, because this runs against installations this migration's author
# cannot inspect:
#   * a row is only retired when nothing references it. Every location-bearing
#     column is counted first, and a referenced row is left alone and reported
#     instead -- retiring a location that encounters or beds point at would hide
#     records rather than clean them up.
#   * matching is exact after case-folding and trimming. Both the recorded
#     spelling and the commonly reported misspelling are listed, so a genuine
#     location that merely contains one of these words is never touched.
class RetireInvalidWardDepartmentNames < ActiveRecord::Migration[8.1]
  REQUIRED_TABLES = %i[location].freeze
  RETIRE_REASON = 'Invalid location name (person name entered in error); unreferenced'

  # Exact names to retire, lower-cased and trimmed. 'nikisoni majaira' is the
  # misspelling this was reported under; the stored value is 'majawira'.
  INVALID_NAMES = [
    'nikisoni majawira',
    'nikisoni majaira',
    'kamanka'
  ].freeze

  # Every column that can point at a location, checked before retiring. Pairs
  # that do not exist in a given installation are skipped.
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

    candidates = invalid_locations
    return say('Nothing to do: no invalidly named locations found.') if candidates.empty?

    # Retiring one candidate can be blocked only by another candidate -- a junk
    # ward classified against a junk department, say. Those are discounted so a
    # single run clears the whole set instead of needing one run per layer.
    candidate_ids = candidates.map { |location| location['location_id'] }

    retired = 0
    skipped = 0

    candidates.each do |location|
      id = location['location_id']
      blockers = references_for(id, ignore_location_ids: candidate_ids)

      if blockers.any?
        skipped += 1
        say("Left ##{id} '#{location['name']}' alone: referenced by #{blockers.join(', ')}.", true)
        next
      end

      retire_location(id)
      retired += 1
      say("Retired ##{id} '#{location['name']}'.", true)
    end

    say("Done: #{retired} retired, #{skipped} left for manual review.")
  end

  # Only rows this migration retired are restored, identified by the reason it
  # wrote. Locations retired for any other purpose are untouched.
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
        AND retire_reason = #{quote(RETIRE_REASON)}
        AND LOWER(TRIM(name)) IN (#{quoted_invalid_names})
    SQL

    say('Restored locations retired by this migration.')
  end

  private

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

  # Returns a description of each reference found, e.g. "encounter.location_id
  # (3)". Empty means the row is safe to retire. Rows belonging to
  # ignore_location_ids are discounted, since those are being retired too.
  def references_for(location_id, ignore_location_ids: [])
    ignored = ignore_location_ids - [location_id]

    LOCATION_REFERENCES.filter_map do |table, column|
      next unless table_exists?(table) && column_exists?(table, column)

      # For the location table itself the row's own key identifies the
      # referrer, so a child that is also being retired can be discounted.
      exclusion = table == 'location' ? not_in_clause('location_id', ignored) : ''

      count = select_value(<<~SQL.squish).to_i
        SELECT COUNT(*) FROM #{table} WHERE #{column} = #{quote(location_id)}#{exclusion}
      SQL
      next if count.zero?

      "#{table}.#{column} (#{count})"
    end + ward_department_references(location_id, ignored)
  end

  # Wards record their department as a 'Department' location attribute holding
  # the department's location_id as a string, so this needs its own comparison
  # rather than the numeric one above.
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

  def not_in_clause(column, ids)
    return '' if ids.empty?

    " AND #{column} NOT IN (#{ids.map { |id| quote(id) }.join(', ')})"
  end

  def retire_location(location_id)
    run_sql(<<~SQL.squish)
      UPDATE location
      SET retired = 1,
          date_retired = #{quote(Time.now)},
          retire_reason = #{quote(RETIRE_REASON)},
          date_changed = #{quote(Time.now)}
      WHERE location_id = #{quote(location_id)}
        AND retired = 0
    SQL
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
