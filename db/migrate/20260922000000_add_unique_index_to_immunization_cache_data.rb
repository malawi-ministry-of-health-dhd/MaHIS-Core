# frozen_string_literal: true

# ImmunizationReportJob#update_cache (and the two controller call sites that write
# the same cache) check-then-write the (name, location_id) row non-atomically, so a
# race between concurrent runs can leave duplicate rows behind. SessionScheduleService
# then sums across every matching row, double-counting missed doses in the UI. Dedupe
# any existing duplicates (keep the most recently updated row) and add a unique index
# so future writes can upsert atomically instead of racing.
class AddUniqueIndexToImmunizationCacheData < ActiveRecord::Migration[8.1]
  def up
    duplicate_groups = select_all(<<~SQL.squish)
      SELECT name, location_id, COUNT(*) AS cnt
      FROM immunization_cache_data
      GROUP BY name, location_id
      HAVING COUNT(*) > 1
    SQL

    duplicate_groups.each do |group|
      location_clause = group['location_id'].nil? ? 'location_id IS NULL' : "location_id = #{connection.quote(group['location_id'])}"

      keeper_id = select_value(<<~SQL.squish)
        SELECT id FROM immunization_cache_data
        WHERE name = #{connection.quote(group['name'])} AND #{location_clause}
        ORDER BY updated_at DESC, id DESC
        LIMIT 1
      SQL

      execute <<~SQL.squish
        DELETE FROM immunization_cache_data
        WHERE name = #{connection.quote(group['name'])} AND #{location_clause} AND id != #{keeper_id}
      SQL
    end

    add_index :immunization_cache_data, %i[name location_id], unique: true,
                                                                name: 'index_immunization_cache_data_on_name_and_location_id'
  end

  def down
    remove_index :immunization_cache_data, name: 'index_immunization_cache_data_on_name_and_location_id'
  end
end
