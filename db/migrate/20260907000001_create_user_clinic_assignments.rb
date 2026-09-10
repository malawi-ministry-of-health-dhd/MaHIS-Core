# frozen_string_literal: true

class CreateUserClinicAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :user_clinic_assignments, primary_key: :user_clinic_assignment_id do |t|
      t.integer :user_id, null: false
      t.string :location_id, null: false
      t.integer :retired, default: 0, null: false
      t.datetime :date_retired
      t.integer :retired_by
      t.integer :creator, null: false
      t.timestamp :date_created, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.timestamps null: false

      t.index :user_id
      t.index :location_id
    end
  end
end
