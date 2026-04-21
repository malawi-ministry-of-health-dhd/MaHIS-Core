class AddPrimaryKeyToUserProperty < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      ALTER TABLE user_property
        DROP PRIMARY KEY,
        ADD PRIMARY KEY (user_id, property);
    SQL
  rescue ActiveRecord::StatementInvalid
    execute <<~SQL
      ALTER TABLE user_property
        ADD PRIMARY KEY (user_id, property);
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE user_property
        DROP PRIMARY KEY;
    SQL
  end
end