class ScopePatientRecordOperationReceiptsByPatient < ActiveRecord::Migration[8.1]
  def change
    return unless table_exists?(:patient_record_operation_receipts)

    if index_exists?(:patient_record_operation_receipts, [:operation_type, :operation_id], name: 'idx_pr_op_receipts_unique')
      remove_index :patient_record_operation_receipts, name: 'idx_pr_op_receipts_unique'
    end

    unless index_exists?(:patient_record_operation_receipts, [:patient_id, :operation_type, :operation_id], name: 'idx_pr_op_receipts_patient_unique')
      add_index :patient_record_operation_receipts,
                [:patient_id, :operation_type, :operation_id],
                unique: true,
                name: 'idx_pr_op_receipts_patient_unique'
    end
  end
end
