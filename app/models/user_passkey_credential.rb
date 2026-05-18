# frozen_string_literal: true

class UserPasskeyCredential < ApplicationRecord
  self.table_name = :user_passkey_credentials

  belongs_to :user, foreign_key: :user_id

  scope :active, -> { where(revoked_at: nil) }

  validates :webauthn_id, presence: true, uniqueness: true
  validates :public_key, presence: true
end
