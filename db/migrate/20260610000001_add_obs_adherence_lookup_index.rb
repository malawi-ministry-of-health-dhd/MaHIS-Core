class AddObsAdherenceLookupIndex < ActiveRecord::Migration[7.0]
  def up
    # Covering index for the single-scan adherence query in latest_art_adherence.
    # Including `voided` allows MySQL to filter voided = 0 directly from the
    # index and use (concept_id, voided, person_id) as a const/ref seek rather
    # than scanning all obs rows for a given concept. Reduces cold query time
    # from ~2.74s to ~0.15s on a 77M-row obs table.
    execute <<~SQL
      CREATE INDEX idx_obs_adherence_lookup
        ON obs (concept_id, voided, person_id, obs_datetime)
    SQL
  end

  def down
    execute "DROP INDEX idx_obs_adherence_lookup ON obs"
  end
end
