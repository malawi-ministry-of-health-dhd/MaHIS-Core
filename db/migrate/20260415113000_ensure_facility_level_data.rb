# frozen_string_literal: true

require 'securerandom'

class EnsureFacilityLevelData < ActiveRecord::Migration[7.0]
  FACILITY_TYPE_NAME = 'Facility Type'
  FACILITY_LEVEL_NAME = 'Facility Level'

  def up
    creator_id = select_value('SELECT user_id FROM users ORDER BY user_id ASC LIMIT 1')
    raise ActiveRecord::IrreversibleMigration, 'Cannot manage facility levels without at least one user' if creator_id.blank?

    facility_type_type_id = select_value(<<~SQL)
      SELECT location_attribute_type_id
      FROM location_attribute_type
      WHERE name = '#{FACILITY_TYPE_NAME}'
      LIMIT 1
    SQL
    return if facility_type_type_id.blank?

    facility_level_type_id = select_value(<<~SQL)
      SELECT location_attribute_type_id
      FROM location_attribute_type
      WHERE name = '#{FACILITY_LEVEL_NAME}'
      LIMIT 1
    SQL

    unless facility_level_type_id.present?
      execute <<~SQL
        INSERT INTO location_attribute_type (
          name,
          datatype,
          creator,
          date_created,
          retired,
          uuid
        )
        VALUES (
          '#{FACILITY_LEVEL_NAME}',
          'string',
          #{creator_id.to_i},
          NOW(),
          0,
          '#{SecureRandom.uuid}'
        )
      SQL

      facility_level_type_id = select_value(<<~SQL)
        SELECT location_attribute_type_id
        FROM location_attribute_type
        WHERE name = '#{FACILITY_LEVEL_NAME}'
        LIMIT 1
      SQL
    end

    backfill_facility_levels!(
      facility_type_type_id: facility_type_type_id.to_i,
      facility_level_type_id: facility_level_type_id.to_i,
      creator_id: creator_id.to_i
    )
  end

  def down
    # Keep seeded/backfilled data on rollback.
  end

  private

  def backfill_facility_levels!(facility_type_type_id:, facility_level_type_id:, creator_id:)
    execute <<~SQL
      UPDATE location_attribute level_attr
      INNER JOIN location_attribute facility_type_attr
        ON facility_type_attr.location_id = level_attr.location_id
      SET level_attr.value_reference = CASE
            WHEN LOWER(TRIM(facility_type_attr.value_reference)) IN ('health centre', 'health center') THEN 'Primary'
            WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'district hospital' THEN 'Secondary'
            WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'central hospital' THEN 'Tertiary'
          END,
          level_attr.voided = 0,
          level_attr.changed_by = COALESCE(level_attr.changed_by, facility_type_attr.creator),
          level_attr.date_changed = NOW()
      WHERE level_attr.attribute_type_id = #{facility_level_type_id}
        AND facility_type_attr.attribute_type_id = #{facility_type_type_id}
        AND COALESCE(facility_type_attr.voided, 0) = 0
        AND LOWER(TRIM(facility_type_attr.value_reference)) IN (
          'health centre',
          'health center',
          'district hospital',
          'central hospital'
        )
    SQL

    execute <<~SQL
      INSERT INTO location_attribute (
        location_id,
        attribute_type_id,
        value_reference,
        uuid,
        creator,
        date_created,
        voided
      )
      SELECT
        facility_type_attr.location_id,
        #{facility_level_type_id},
        CASE
          WHEN LOWER(TRIM(facility_type_attr.value_reference)) IN ('health centre', 'health center') THEN 'Primary'
          WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'district hospital' THEN 'Secondary'
          WHEN LOWER(TRIM(facility_type_attr.value_reference)) = 'central hospital' THEN 'Tertiary'
        END,
        UUID(),
        COALESCE(facility_type_attr.creator, #{creator_id}),
        COALESCE(facility_type_attr.date_created, NOW()),
        0
      FROM location_attribute facility_type_attr
      LEFT JOIN location_attribute level_attr
        ON level_attr.location_id = facility_type_attr.location_id
       AND level_attr.attribute_type_id = #{facility_level_type_id}
      WHERE facility_type_attr.attribute_type_id = #{facility_type_type_id}
        AND COALESCE(facility_type_attr.voided, 0) = 0
        AND LOWER(TRIM(facility_type_attr.value_reference)) IN (
          'health centre',
          'health center',
          'district hospital',
          'central hospital'
        )
        AND level_attr.location_attribute_id IS NULL
    SQL
  end
end
