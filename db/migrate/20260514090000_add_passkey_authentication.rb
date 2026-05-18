# frozen_string_literal: true

class AddPasskeyAuthentication < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :webauthn_id, :string
    add_index :users, :webauthn_id, unique: true

    create_table :user_passkey_credentials do |t|
      t.integer :user_id, null: false
      t.string :webauthn_id, null: false
      t.text :public_key, null: false
      t.integer :sign_count, null: false, default: 0
      t.string :nickname
      t.string :transports
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :user_passkey_credentials, :webauthn_id, unique: true
    add_index :user_passkey_credentials, :user_id
    add_foreign_key :user_passkey_credentials, :users, column: :user_id, primary_key: :user_id

    create_table :passkey_challenges do |t|
      t.integer :user_id, null: false
      t.string :token, null: false
      t.string :challenge, null: false
      t.string :ceremony, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :passkey_challenges, :token, unique: true
    add_index :passkey_challenges, %i[user_id ceremony]
    add_foreign_key :passkey_challenges, :users, column: :user_id, primary_key: :user_id
  end
end
