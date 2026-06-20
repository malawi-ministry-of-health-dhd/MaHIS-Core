class AddPrimaryKeyToUserProperty < ActiveRecord::Migration[8.1]
  EXPECTED_PRIMARY_KEY = %w[user_id property].freeze

  def up
    current_primary_key = connection.primary_keys(:user_property).map(&:to_s)
    return if current_primary_key == EXPECTED_PRIMARY_KEY

    if current_primary_key.any?
      raise ActiveRecord::MigrationError,
            "user_property has unexpected primary key #{current_primary_key.inspect}; refusing a destructive replacement"
    end

    if tidb?
      execute 'ALTER TABLE user_property ADD PRIMARY KEY (user_id, property) NONCLUSTERED;'
    else
      execute 'ALTER TABLE user_property ADD PRIMARY KEY (user_id, property);'
    end
  end

  def down
    return unless connection.primary_keys(:user_property).map(&:to_s) == EXPECTED_PRIMARY_KEY

    execute 'ALTER TABLE user_property DROP PRIMARY KEY;'
  end

  private

  def tidb?
    connection.select_value('SELECT VERSION()').to_s.match?(/tidb/i)
  end
end
