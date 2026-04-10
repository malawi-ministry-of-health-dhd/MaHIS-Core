# frozen_string_literal: true

require 'securerandom'

class AddTransportationPersonAttributeType < ActiveRecord::Migration[8.1]
  ATTRIBUTE_NAME = 'Transportation'
  ATTRIBUTE_DESCRIPTION = 'Patient transportation mode'

  def up
    return if transportation_attribute_exists?
    return if transport_mode_attribute_exists?

    creator_id = select_value('SELECT user_id FROM users ORDER BY user_id ASC LIMIT 1')
    raise ActiveRecord::IrreversibleMigration, 'Cannot create Transportation attribute type without a user' if creator_id.blank?

    execute <<~SQL
      INSERT INTO person_attribute_type (
        name,
        description,
        creator,
        date_created,
        retired,
        searchable,
        uuid
      )
      VALUES (
        '#{ATTRIBUTE_NAME}',
        '#{ATTRIBUTE_DESCRIPTION}',
        #{creator_id.to_i},
        NOW(),
        0,
        0,
        '#{SecureRandom.uuid}'
      )
    SQL
  end

  def down
    execute <<~SQL
      DELETE FROM person_attribute_type
      WHERE name = '#{ATTRIBUTE_NAME}'
        AND person_attribute_type_id NOT IN (
          SELECT DISTINCT person_attribute_type_id
          FROM person_attribute
          WHERE person_attribute_type_id IS NOT NULL
        )
    SQL
  end

  private

  def transportation_attribute_exists?
    select_value(<<~SQL).present?
      SELECT person_attribute_type_id
      FROM person_attribute_type
      WHERE name = '#{ATTRIBUTE_NAME}'
      LIMIT 1
    SQL
  end

  def transport_mode_attribute_exists?
    select_value(<<~SQL).present?
      SELECT person_attribute_type_id
      FROM person_attribute_type
      WHERE name = 'Mode of transport'
      LIMIT 1
    SQL
  end
end
