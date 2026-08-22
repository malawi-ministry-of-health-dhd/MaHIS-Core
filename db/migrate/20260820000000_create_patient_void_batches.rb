# frozen_string_literal: true

# One row per patient-level void, so a void can be reversed by restoring
# exactly the rows it voided (see PatientService#unvoid_patient).
class CreatePatientVoidBatches < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:patient_void_batches)

    create_table :patient_void_batches do |t|
      t.integer :patient_id, null: false
      t.string :reason, limit: 191, null: false
      t.integer :voided_by
      t.datetime :date_voided, null: false
      t.json :row_counts
      t.integer :restored_by
      t.datetime :restored_at
      t.string :restore_reason, limit: 191

      t.timestamps
    end

    add_index :patient_void_batches, %i[patient_id restored_at], name: 'idx_patient_void_batches_patient'
  end
end
