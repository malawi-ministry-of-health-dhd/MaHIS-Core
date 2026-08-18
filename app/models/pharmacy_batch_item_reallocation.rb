# frozen_string_literal: true

class PharmacyBatchItemReallocation < VoidableRecord
  belongs_to :item, class_name: 'PharmacyBatchItem', foreign_key: :batch_item_id
  belongs_to :location, optional: true
  belongs_to :program, foreign_key: :program_id, primary_key: :program_id, optional: true

  before_save :sync_item_context

  # Scopes for filtering
  scope :for_program, ->(program_id) { where(program_id: program_id) if program_id.present? }
  scope :for_location, ->(location_id) { where(location_id: location_id) if location_id.present? }

  private

  def sync_item_context
    if item.present?
      self.program_id ||= item.program_id
      self.location_id ||= item.location_id unless location_id.present? # Don't override reallocation destination
    end
    # Program ID should be set from item or explicitly
  end
end
