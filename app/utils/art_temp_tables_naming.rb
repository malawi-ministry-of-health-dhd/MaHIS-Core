# frozen_string_literal: true

# Helper module for generating location-specific temporary table names
# This allows concurrent report generation for different sites without data conflicts
module ArtTempTablesNaming
  # Generate location-specific table name
  def temp_table_name(base_name, start: false)
    suffix = start ? '_start' : ''
    location_id = Location.current&.location_id || 'default'
    "#{base_name}#{suffix}_loc_#{location_id}"
  end

  # Generate location-specific index name
  def temp_index_name(base_name, start: false)
    suffix = start ? '_start' : ''
    location_id = Location.current&.location_id || 'default'
    "#{base_name}#{suffix}_loc_#{location_id}"
  end

  def idx_temp_initiated_on_art
    temp_index_name('idx_temp_initiated_on_art')
  end

  def idx_temp_initiated_on_tpt
    temp_index_name('idx_temp_initiated_on_tpt')
  end
  
  def temp_initiated_on_tpt
    temp_table_name('temp_initiated_on_tpt')
  end

  def temp_initiated_on_tpt
    temp_table_name('temp_initiated_on_tpt')
  end

  def temp_initiated_on_art 
    temp_table_name('temp_initiated_on_art')
  end

  # Cohort tables
  def temp_cohort_members
    temp_table_name('temp_cohort_members')
  end

  def temp_earliest_start_date
    temp_table_name('temp_earliest_start_date')
  end

  def temp_other_patient_types
    temp_table_name('temp_other_patient_types')
  end

  def temp_register_start_date
    temp_table_name('temp_register_start_date')
  end

  def temp_order_details
    temp_table_name('temp_order_details')
  end

  def temp_art_start_date
    temp_table_name('temp_art_start_date')
  end

  def temp_patient_tb_status
    temp_table_name('temp_patient_tb_status')
  end

  def temp_latest_tb_status
    temp_table_name('temp_latest_tb_status')
  end

  def tmp_max_adherence
    temp_table_name('tmp_max_adherence')
  end

  def temp_pregnant_obs
    temp_table_name('temp_pregnant_obs')
  end

  def temp_patient_side_effects
    temp_table_name('temp_patient_side_effects')
  end

  def temp_maternal_status
    temp_table_name('temp_maternal_status')
  end

  # Outcome tables (support start parameter)
  def temp_patient_outcomes(start: false)
    temp_table_name('temp_patient_outcomes', start: start)
  end

  def temp_max_drug_orders(start: false)
    temp_table_name('temp_max_drug_orders', start: start)
  end

  def temp_min_auto_expire_date(start: false)
    temp_table_name('temp_min_auto_expire_date', start: start)
  end

  def temp_max_patient_state(start: false)
    temp_table_name('temp_max_patient_state', start: start)
  end

  def temp_current_state(start: false)
    temp_table_name('temp_current_state', start: start)
  end

  def temp_current_medication(start: false)
    temp_table_name('temp_current_medication', start: start)
  end

  def temp_tb_confirmed_and_on_treatment(start: false)
    temp_table_name('temp_tb_confirmed_and_on_treatment', start: start)
  end

  def temp_tb_screened(start: false)
    temp_table_name('temp_tb_screened', start: start)
  end

  # MySQL function names (location-specific)
  def died_in_function_name
    location_id = Location.current&.location_id || 'default'
    "died_in_loc_#{location_id}"
  end
end
