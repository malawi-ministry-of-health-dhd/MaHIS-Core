# frozen_string_literal: true

# Pharmacy stock verification model
class PharmacyStockVerification < VoidableRecord
  include Locatable

  belongs_to :program, foreign_key: :program_id, primary_key: :program_id, optional: true
  has_many :pharmac_obs, class_name: 'Pharmacy', foreign_key: :stock_verification_id

  before_save :set_program_id

  validates :verification_date, presence: true
  validates :reason, presence: true

  # Scopes for filtering
  scope :for_program, ->(program_id) { where(program_id: program_id) if program_id.present? }
  scope :for_location, ->(location_id) { where(location_id: location_id) if location_id.present? }

  private

  def set_program_id
    self.program_id ||= User.current&.program&.program_id
  end
end
