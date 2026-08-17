# frozen_string_literal: true

class Pharmacy < VoidableRecord
  self.table_name = :pharmacy_obs
  self.primary_key = :pharmacy_module_id

  include Locatable

  belongs_to :item, class_name: 'PharmacyBatchItem',
                    foreign_key: :batch_item_id,
                    optional: true
  belongs_to :type, class_name: 'PharmacyEncounterType',
                    foreign_key: :pharmacy_encounter_type
  belongs_to :dispensation, class_name: 'Observation',
                            foreign_key: :dispensation_obs_id,
                            optional: true
  belongs_to :user, foreign_key: :creator, optional: true
  belongs_to :stock_verification, class_name: 'PharmacyStockVerification', foreign_key: :stock_verification_id,
                                  optional: true
  belongs_to :program, foreign_key: :program_id, primary_key: :program_id, optional: true

  before_save :sync_item_context

  # Scopes for filtering
  scope :for_program, ->(program_id) { where(program_id: program_id) if program_id.present? }
  scope :for_location, ->(location_id) { where(location_id: location_id) if location_id.present? }

  private

  def sync_item_context
    if item.present?
      self.program_id ||= item.program_id
      self.location_id ||= item.location_id
    else
      self.program_id ||= User.current&.program&.program_id
    end
  end
end
