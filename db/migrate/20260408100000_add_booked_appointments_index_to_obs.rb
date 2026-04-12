class AddBookedAppointmentsIndexToObs < ActiveRecord::Migration[6.1]
  def up
    # Composite index to support the booked_appointments query which filters on
    # concept_id + value_datetime + location_id + voided — reducing scan from
    # hundreds of thousands of encounter rows to only obs rows matching the date.
    unless index_exists?(:obs, [:concept_id, :value_datetime, :location_id, :voided],
                         name: 'idx_obs_appt_concept_date_location_voided')
      add_index :obs, [:concept_id, :value_datetime, :location_id, :voided],
                name: 'idx_obs_appt_concept_date_location_voided',
                algorithm: :inplace
    end
  end

  def down
    remove_index :obs, name: 'idx_obs_appt_concept_date_location_voided' if
      index_exists?(:obs, name: 'idx_obs_appt_concept_date_location_voided')
  end
end
