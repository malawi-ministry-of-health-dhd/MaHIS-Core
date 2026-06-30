class AddObsConceptPersonDatetimeIndex < ActiveRecord::Migration[7.0]
  def up
    # Composite index to speed up the adherence tmp_max_adherence INSERT which
    # filters obs by concept_id = <adherence concept>, person_id (join), and
    # obs_datetime (range). Without this, MySQL does a full scan of 77M+ rows.
    execute <<~SQL
      CREATE INDEX idx_obs_concept_person_datetime
        ON obs (concept_id, person_id, obs_datetime)
    SQL
  end

  def down
    execute "DROP INDEX idx_obs_concept_person_datetime ON obs"
  end
end
