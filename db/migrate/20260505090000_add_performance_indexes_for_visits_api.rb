# frozen_string_literal: true

class AddPerformanceIndexesForVisitsApi < ActiveRecord::Migration[8.1]
  def change
    add_index :visit, %i[location_id date_started],
              name: 'index_visit_on_location_id_and_date_started',
              if_not_exists: true

    add_index :visit, %i[location_id date_stopped],
              name: 'index_visit_on_location_id_and_date_stopped',
              if_not_exists: true

    add_index :visit, %i[patient_id date_stopped],
              name: 'index_visit_on_patient_id_and_date_stopped',
              if_not_exists: true

    add_index :encounter, %i[visit_id program_id],
              name: 'index_encounter_on_visit_id_and_program_id',
              if_not_exists: true

    add_index :patient_identifier, %i[patient_id identifier_type voided],
              name: 'index_patient_identifier_on_patient_type_voided',
              if_not_exists: true

    add_index :person_name, %i[person_id voided date_created],
              name: 'index_person_name_on_person_voided_date_created',
              if_not_exists: true
  end
end
