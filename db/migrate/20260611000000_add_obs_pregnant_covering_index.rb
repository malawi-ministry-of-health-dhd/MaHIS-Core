class AddObsPregnantCoveringIndex < ActiveRecord::Migration[6.1]
  def up
    # Covering index for the pregnant obs lookup in cohort_builder#load_temp_pregnant_obs.
    # Columns ordered to:
    #   1. concept_id  — IN list (8 values), most selective first
    #   2. value_coded — IN list (4 values), further reduces rows
    #   3. voided      — equality = 0
    #   4. obs_datetime — range filter + ORDER BY for MIN()
    #   5. person_id   — included so no table row-lookup is needed (covering)
    # Without this, MySQL falls back to idx_obs_concept_person_datetime which
    # doesn't cover value_coded/voided and requires a full table-row fetch per hit.
    add_index :obs,
              %i[concept_id value_coded voided obs_datetime person_id],
              name: 'idx_obs_preg_covering',
              algorithm: :inplace
  end

  def down
    remove_index :obs, name: 'idx_obs_preg_covering'
  end
end
