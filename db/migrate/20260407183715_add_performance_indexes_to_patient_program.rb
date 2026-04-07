# frozen_string_literal: true

class AddPerformanceIndexesToPatientProgram < ActiveRecord::Migration[6.1]
  def change
    # Add composite index on (location_id, voided) for filtering active programs at a location
    # This supports the default_scope filter on voided: 0 across location-based queries
    unless index_exists?(
      :patient_program, %i[location_id voided]
    )
      add_index :patient_program, %i[location_id voided],
                name: 'index_patient_program_on_location_id_and_voided'
    end

    # Add single index on date_enrolled for date-range queries
    # Improves performance when filtering by enrollment date
    add_index :patient_program, :date_enrolled, name: 'index_patient_program_on_date_enrolled' unless index_exists?(
      :patient_program, :date_enrolled
    )

    # Add composite index on (program_id, location_id) for reporting joins
    # Optimizes queries that filter by both program and location
    unless index_exists?(
      :patient_program, %i[program_id location_id]
    )
      add_index :patient_program, %i[program_id location_id],
                name: 'index_patient_program_on_program_id_and_location_id'
    end
  end
end
