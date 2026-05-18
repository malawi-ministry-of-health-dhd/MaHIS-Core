# frozen_string_literal: true

class PasskeyChallenge < ApplicationRecord
  belongs_to :user, foreign_key: :user_id

  REGISTRATION = 'registration'
  AUTHENTICATION = 'authentication'

  validates :token, :challenge, :ceremony, :expires_at, presence: true

  scope :active, -> { where('expires_at > ?', Time.current) }

  def expired?
    expires_at <= Time.current
  end
end
