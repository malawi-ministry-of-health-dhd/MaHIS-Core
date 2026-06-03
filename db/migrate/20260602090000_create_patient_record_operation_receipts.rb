class CreatePatientRecordOperationReceipts < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:patient_record_operation_receipts)

    create_table :patient_record_operation_receipts do |t|
      t.integer :patient_id
      t.string :operation_type, limit: 100, null: false
      t.string :operation_id, limit: 191, null: false
      t.string :payload_hash, limit: 64
      t.string :status, limit: 20, null: false, default: 'processing'
      t.string :target_type, limit: 100
      t.string :target_id, limit: 191
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :patient_record_operation_receipts,
              [:operation_type, :operation_id],
              unique: true,
              name: 'idx_pr_op_receipts_unique'
    add_index :patient_record_operation_receipts,
              [:patient_id, :operation_type],
              name: 'idx_pr_op_receipts_patient_type'
    add_index :patient_record_operation_receipts,
              :status,
              name: 'idx_pr_op_receipts_status'
  end
end
