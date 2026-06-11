# frozen_string_literal: true

class AddCompositeIndexToPatientProgram < ActiveRecord::Migration[7.0]
  def change
    add_index :patient_program, %i[patient_id program_id],
              name: 'index_patient_program_on_patient_id_and_program_id'
  end
end
