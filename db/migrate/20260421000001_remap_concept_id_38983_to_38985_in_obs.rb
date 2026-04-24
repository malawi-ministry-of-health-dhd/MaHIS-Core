class RemapConceptId38983To38985InObs < ActiveRecord::Migration[6.1]
  def up
    execute <<-SQL
      UPDATE obs
      SET concept_id = 38985
      WHERE concept_id = 38983
        AND voided = 0;
    SQL
  end

  def down
    execute <<-SQL
      UPDATE obs
      SET concept_id = 38983
      WHERE concept_id = 38985
        AND voided = 0;
    SQL
  end
end
