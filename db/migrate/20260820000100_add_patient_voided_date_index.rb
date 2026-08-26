# frozen_string_literal: true

# The voided-patients admin list filters on voided + date_voided; `patient`
# only had an index on voided_by, so that query scanned the whole table.
class AddPatientVoidedDateIndex < ActiveRecord::Migration[8.1]
  def change
    return if index_exists?(:patient, %i[voided date_voided], name: 'idx_patient_voided_date_voided')

    add_index :patient, %i[voided date_voided], name: 'idx_patient_voided_date_voided'
  end
end
