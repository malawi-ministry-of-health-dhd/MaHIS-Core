# frozen_string_literal: true

class AddClinicalDeduplicationIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :obs,
              %i[person_id voided obs_group_id obs_id],
              name: 'idx_obs_patient_voided_group_id',
              algorithm: :inplace,
              if_not_exists: true

    add_index :orders,
              %i[patient_id voided order_id],
              name: 'idx_orders_patient_voided_id',
              algorithm: :inplace,
              if_not_exists: true
  end
end
