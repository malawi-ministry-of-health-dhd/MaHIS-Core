class RemapConceptId39497To39498InObs < ActiveRecord::Migration[6.1]
  BMI_MEASURED_CONCEPT_ID = 39497

  def up
    bmi_id = select_value("SELECT concept_id FROM concept_name WHERE name = 'BMI' AND voided = 0 LIMIT 1")

    raise "BMI concept not found" unless bmi_id

    execute <<-SQL
      UPDATE obs
      SET concept_id = #{bmi_id}
      WHERE concept_id = #{BMI_MEASURED_CONCEPT_ID}
        AND voided = 0;
    SQL
  end

  def down
    bmi_id = select_value("SELECT concept_id FROM concept_name WHERE name = 'BMI' AND voided = 0 LIMIT 1")

    raise "BMI concept not found" unless bmi_id

    execute <<-SQL
      UPDATE obs
      SET concept_id = #{BMI_MEASURED_CONCEPT_ID}
      WHERE concept_id = #{bmi_id}
        AND voided = 0;
    SQL
  end
end
