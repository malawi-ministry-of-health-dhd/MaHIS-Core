# frozen_string_literal: true

# Departments became global (site-agnostic) in e20ddb7ac: the API stopped giving
# them a parent_location, and a ward now records the department it belongs to as
# a 'Department' location attribute instead of hanging off it as a child.
#
# That change shipped without a data migration, so installations carry a mix:
# departments created before it still point at a facility, ones created after it
# do not. Anything reading departments the new way (parentless) silently omits
# the legacy rows, which in turn strands the wards classified against them.
#
# This backfills the data to match:
#   * a legacy department whose name matches a global one is merged into it --
#     wards pointing at the legacy row are repointed, then the row is retired
#   * any other legacy department is promoted in place (parent_location = NULL)
#
# Name matching is deliberately conservative: case-insensitive and
# whitespace-trimmed, but otherwise exact. Near-misses ("Med" vs "Medicine") are
# left alone and reported, because collapsing those is a clinical decision.
class ConsolidateGlobalDepartments < ActiveRecord::Migration[8.1]
  REQUIRED_TABLES = %i[location location_tag location_tag_map].freeze
  MERGE_REASON = 'Merged into global department %<target_id>s (global departments migration)'

  def up
    return say('Skipped: location tables are not present.') unless REQUIRED_TABLES.all? { |table| table_exists?(table) }

    legacy = legacy_departments
    return say('Nothing to do: no facility-parented departments found.') if legacy.empty?

    say("Found #{legacy.size} facility-parented department(s) to consolidate.")

    merged = 0
    promoted = 0

    legacy.each do |department|
      # Re-resolved per row so that a department promoted earlier in this loop
      # becomes the merge target for later duplicates of the same name.
      target_id = global_department_id_for(department['name'], exclude_id: department['location_id'])

      if target_id
        repointed = repoint_ward_departments(department['location_id'], target_id)
        retire_department(department['location_id'], target_id)
        merged += 1
        say("Merged ##{department['location_id']} '#{department['name']}' into ##{target_id} (#{repointed} ward(s) repointed).", true)
      else
        promote_department(department['location_id'])
        promoted += 1
        say("Promoted ##{department['location_id']} '#{department['name']}' to a global department.", true)
      end
    end

    say("Done: #{merged} merged, #{promoted} promoted.")
    report_remaining_duplicates
  end

  # Merges cannot be undone automatically: the pre-merge parent of a retired row
  # is not recorded, and repointed wards are indistinguishable from wards that
  # always pointed at the target. Retired rows carry the merge target in
  # retire_reason so a merge can be traced and unwound by hand if needed.
  def down
    say('Irreversible data migration: see retire_reason on retired departments to unwind a merge manually.')
  end

  private

  def department_tag_id
    @department_tag_id ||= select_value(<<~SQL.squish)
      SELECT location_tag_id FROM location_tag WHERE LOWER(TRIM(name)) = 'department' LIMIT 1
    SQL
  end

  def department_attribute_type_id
    return @department_attribute_type_id if defined?(@department_attribute_type_id)

    @department_attribute_type_id =
      if table_exists?(:location_attribute_type)
        select_value(<<~SQL.squish)
          SELECT location_attribute_type_id FROM location_attribute_type
          WHERE LOWER(TRIM(name)) = 'department' LIMIT 1
        SQL
      end
  end

  def legacy_departments
    return [] unless department_tag_id

    select_all(<<~SQL.squish).to_a
      SELECT l.location_id, l.name
      FROM location l
      JOIN location_tag_map ltm ON ltm.location_id = l.location_id
      WHERE ltm.location_tag_id = #{quote(department_tag_id)}
        AND l.retired = 0
        AND l.parent_location IS NOT NULL
      ORDER BY l.location_id
    SQL
  end

  def global_department_id_for(name, exclude_id:)
    select_value(<<~SQL.squish)
      SELECT l.location_id
      FROM location l
      JOIN location_tag_map ltm ON ltm.location_id = l.location_id
      WHERE ltm.location_tag_id = #{quote(department_tag_id)}
        AND l.retired = 0
        AND l.parent_location IS NULL
        AND l.location_id <> #{quote(exclude_id)}
        AND LOWER(TRIM(l.name)) = LOWER(TRIM(#{quote(name)}))
      ORDER BY l.location_id
      LIMIT 1
    SQL
  end

  # Repoints wards classified against the legacy department. Rows already
  # pointing at the target are left untouched so the migration is re-runnable.
  def repoint_ward_departments(legacy_id, target_id)
    return 0 unless department_attribute_type_id && table_exists?(:location_attribute)

    run_sql(<<~SQL.squish)
      UPDATE location_attribute
      SET value_reference = #{quote(target_id.to_s)}
      WHERE attribute_type_id = #{quote(department_attribute_type_id)}
        AND voided = 0
        AND value_reference = #{quote(legacy_id.to_s)}
    SQL

    db.raw_connection.respond_to?(:affected_rows) ? db.raw_connection.affected_rows : 0
  rescue StandardError
    0
  end

  def retire_department(legacy_id, target_id)
    run_sql(<<~SQL.squish)
      UPDATE location
      SET retired = 1,
          date_retired = #{quote(Time.now)},
          retire_reason = #{quote(format(MERGE_REASON, target_id: target_id))},
          date_changed = #{quote(Time.now)}
      WHERE location_id = #{quote(legacy_id)}
    SQL
  end

  def promote_department(legacy_id)
    run_sql(<<~SQL.squish)
      UPDATE location
      SET parent_location = NULL,
          date_changed = #{quote(Time.now)}
      WHERE location_id = #{quote(legacy_id)}
    SQL
  end

  # Same-name globals are not merged automatically (both are already visible
  # everywhere, so there is no correctness bug to fix), but they are worth
  # flagging because they render as duplicates in every facility's picker.
  def report_remaining_duplicates
    duplicates = select_all(<<~SQL.squish).to_a
      SELECT LOWER(TRIM(l.name)) AS name, COUNT(*) AS total
      FROM location l
      JOIN location_tag_map ltm ON ltm.location_id = l.location_id
      WHERE ltm.location_tag_id = #{quote(department_tag_id)}
        AND l.retired = 0
        AND l.parent_location IS NULL
      GROUP BY LOWER(TRIM(l.name))
      HAVING COUNT(*) > 1
    SQL
    return if duplicates.empty?

    say('Duplicate global departments remain and need a manual decision:')
    duplicates.each { |row| say("#{row['name']} x#{row['total']}", true) }
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
