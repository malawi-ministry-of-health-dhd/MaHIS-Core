# frozen_string_literal: true

class AddLoginAndObservationPerformanceIndexes < ActiveRecord::Migration[8.1]
  def up
    add_index :obs, %i[location_id voided encounter_id obs_datetime],
              name: 'idx_obs_loc_void_encounter_time',
              algorithm: :inplace,
              if_not_exists: true

    add_index :obs, %i[location_id voided concept_id value_coded obs_datetime],
              name: 'idx_obs_loc_void_concept_value_time',
              algorithm: :inplace,
              if_not_exists: true

    add_index :encounter, %i[location_id voided program_id date_created],
              name: 'idx_encounter_loc_void_program_created',
              algorithm: :inplace,
              if_not_exists: true

    add_index :users, :username,
              name: 'idx_users_username',
              algorithm: :inplace,
              if_not_exists: true

    add_index :users, %i[authentication_token token_expiry_time],
              name: 'idx_users_auth_token_expiry',
              algorithm: :inplace,
              if_not_exists: true

    add_index :location_attribute, %i[location_id attribute_type_id voided location_attribute_id],
              name: 'idx_location_attr_lookup',
              algorithm: :inplace,
              if_not_exists: true
  end

  def down
    remove_index :location_attribute, name: 'idx_location_attr_lookup', if_exists: true
    remove_index :users, name: 'idx_users_auth_token_expiry', if_exists: true
    remove_index :users, name: 'idx_users_username', if_exists: true
    remove_index :encounter, name: 'idx_encounter_loc_void_program_created', if_exists: true
    remove_index :obs, name: 'idx_obs_loc_void_concept_value_time', if_exists: true
    remove_index :obs, name: 'idx_obs_loc_void_encounter_time', if_exists: true
  end
end
