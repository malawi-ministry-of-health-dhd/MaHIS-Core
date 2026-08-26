# frozen_string_literal: true

class DropUnusedPatientServiceWaitingTimeView < ActiveRecord::Migration[8.1]
  def up
    execute 'DROP VIEW IF EXISTS patient_service_waiting_time'
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
