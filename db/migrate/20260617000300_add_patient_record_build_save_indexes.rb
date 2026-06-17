# frozen_string_literal: true

class AddPatientRecordBuildSaveIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :encounter, %i[patient_id voided encounter_datetime],
              name: 'idx_encounter_patient_voided_datetime',
              algorithm: :inplace,
              if_not_exists: true

    add_index :encounter, %i[patient_id program_id voided encounter_datetime],
              name: 'idx_encounter_patient_program_voided_time',
              algorithm: :inplace,
              if_not_exists: true

    add_index :obs, %i[encounter_id voided obs_group_id],
              name: 'idx_obs_encounter_voided_group',
              algorithm: :inplace,
              if_not_exists: true

    add_index :concept_name, %i[concept_id voided concept_name_id],
              name: 'idx_concept_name_concept_voided_id',
              algorithm: :inplace,
              if_not_exists: true

    add_index :patient_program, %i[patient_id program_id voided date_completed date_enrolled],
              name: 'idx_patient_program_active_lookup',
              algorithm: :inplace,
              if_not_exists: true

    add_index :patient_state, %i[patient_program_id voided start_date end_date],
              name: 'idx_patient_state_program_voided_start',
              algorithm: :inplace,
              if_not_exists: true

    add_index :orders, %i[patient_id start_date order_id],
              name: 'idx_orders_patient_start_order',
              algorithm: :inplace,
              if_not_exists: true

    add_index :orders, %i[encounter_id voided order_id],
              name: 'idx_orders_encounter_voided_order',
              algorithm: :inplace,
              if_not_exists: true

    add_index :relationship, %i[person_a relationship person_b voided],
              name: 'idx_relationship_a_type_b_voided',
              algorithm: :inplace,
              if_not_exists: true

    add_index :relationship, %i[person_b relationship person_a voided],
              name: 'idx_relationship_b_type_a_voided',
              algorithm: :inplace,
              if_not_exists: true

    add_index :program, :name,
              name: 'idx_program_name',
              algorithm: :inplace,
              if_not_exists: true

    add_index :encounter_type, :name,
              name: 'idx_encounter_type_name',
              algorithm: :inplace,
              if_not_exists: true

    add_index :patient_identifier_type, :name,
              name: 'idx_patient_identifier_type_name',
              algorithm: :inplace,
              if_not_exists: true
  end

  def down
    remove_index :patient_identifier_type, name: 'idx_patient_identifier_type_name', if_exists: true
    remove_index :encounter_type, name: 'idx_encounter_type_name', if_exists: true
    remove_index :program, name: 'idx_program_name', if_exists: true
    remove_index :relationship, name: 'idx_relationship_b_type_a_voided', if_exists: true
    remove_index :relationship, name: 'idx_relationship_a_type_b_voided', if_exists: true
    remove_index :orders, name: 'idx_orders_encounter_voided_order', if_exists: true
    remove_index :orders, name: 'idx_orders_patient_start_order', if_exists: true
    remove_index :patient_state, name: 'idx_patient_state_program_voided_start', if_exists: true
    remove_index :patient_program, name: 'idx_patient_program_active_lookup', if_exists: true
    remove_index :concept_name, name: 'idx_concept_name_concept_voided_id', if_exists: true
    remove_index :obs, name: 'idx_obs_encounter_voided_group', if_exists: true
    remove_index :encounter, name: 'idx_encounter_patient_program_voided_time', if_exists: true
    remove_index :encounter, name: 'idx_encounter_patient_voided_datetime', if_exists: true
  end
end
