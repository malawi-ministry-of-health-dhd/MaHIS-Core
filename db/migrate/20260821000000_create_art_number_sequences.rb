# frozen_string_literal: true

class CreateArtNumberSequences < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:art_number_sequence)

    create_table :art_number_sequence do |t|
      t.integer :location_id, null: false
      t.string :site_prefix, null: false
      t.bigint :last_sequence, null: false, default: 0
      t.timestamps
    end

    add_index :art_number_sequence, :location_id, unique: true
    add_foreign_key :art_number_sequence, :location,
                    column: :location_id, primary_key: :location_id

    GlobalProperty.unscoped.where(property: 'site_prefix').where.not(location_id: nil).find_each do |property|
      execute <<~SQL.squish
        INSERT INTO art_number_sequence (location_id, site_prefix, last_sequence, created_at, updated_at)
        VALUES (#{connection.quote(property.location_id)},
                 #{connection.quote(property.property_value)},
                 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
  end

  def down
    drop_table :art_number_sequence
  end
end
