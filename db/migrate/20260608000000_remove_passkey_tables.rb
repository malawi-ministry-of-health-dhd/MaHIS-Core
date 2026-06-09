# frozen_string_literal: true

class RemovePasskeyTables < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :passkey_challenges, :users if foreign_key_exists?(:passkey_challenges, :users)
    remove_foreign_key :user_passkey_credentials, :users if foreign_key_exists?(:user_passkey_credentials, :users)

    drop_table :passkey_challenges, if_exists: true
    drop_table :user_passkey_credentials, if_exists: true

    remove_index :users, :webauthn_id, if_exists: true
    remove_column :users, :webauthn_id, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
