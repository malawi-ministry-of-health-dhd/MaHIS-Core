# frozen_string_literal: true

class AddMnhStatsAndSidekiqPerformanceIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :encounter, %i[location_id voided program_id encounter_datetime patient_id],
              name: 'idx_encounter_mnh_location_program_time',
              algorithm: :inplace,
              if_not_exists: true

    add_index :encounter, %i[location_id date_created patient_id],
              name: 'idx_encounter_patient_sync_location_date',
              algorithm: :inplace,
              if_not_exists: true

    add_index :encounter, %i[date_created patient_id],
              name: 'idx_encounter_patient_sync_date',
              algorithm: :inplace,
              if_not_exists: true

    add_index :obs, %i[location_id voided concept_id obs_datetime person_id],
              name: 'idx_obs_mnh_location_concept_time',
              algorithm: :inplace,
              if_not_exists: true

    add_index :patient_program, %i[program_id location_id voided date_enrolled patient_id],
              name: 'idx_patient_program_mnh_counts',
              algorithm: :inplace,
              if_not_exists: true

    add_index :notification_alert, %i[alert_read date_to_expire alert_id],
              name: 'idx_notification_alert_expiry_clear',
              algorithm: :inplace,
              if_not_exists: true
  end

  def down
    remove_index :notification_alert, name: 'idx_notification_alert_expiry_clear', if_exists: true
    remove_index :patient_program, name: 'idx_patient_program_mnh_counts', if_exists: true
    remove_index :obs, name: 'idx_obs_mnh_location_concept_time', if_exists: true
    remove_index :encounter, name: 'idx_encounter_patient_sync_date', if_exists: true
    remove_index :encounter, name: 'idx_encounter_patient_sync_location_date', if_exists: true
    remove_index :encounter, name: 'idx_encounter_mnh_location_program_time', if_exists: true
  end
end
