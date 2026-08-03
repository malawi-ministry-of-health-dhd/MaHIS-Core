# frozen_string_literal: true

class AddArvNumberDateLookupIndex < ActiveRecord::Migration[8.1]
  INDEX_NAME = 'index_pi_on_voided_type_and_date_created'

  def change
    return if index_exists?(:patient_identifier, %i[voided identifier_type date_created], name: INDEX_NAME)

    add_index :patient_identifier,
              %i[voided identifier_type date_created],
              name: INDEX_NAME
  end
end
