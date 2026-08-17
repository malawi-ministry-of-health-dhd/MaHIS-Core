# frozen_string_literal: true

class PharmacyBatch < VoidableRecord
  include Locatable

  belongs_to :program, foreign_key: :program_id, primary_key: :program_id, optional: true
  has_many :items, class_name: 'PharmacyBatchItem'

  after_void :void_items
  before_save :set_program_id

  # Scopes for filtering
  scope :for_program, ->(program_id) { where(program_id: program_id) if program_id.present? }
  scope :for_location, ->(location_id) { where(location_id: location_id) if location_id.present? }

  def as_json(options = {})
    super(options.merge(
      include: {
        items: {
          methods: %i[drug_name]
        }
      }
    ))
  end

  def void_items(reason)
    items.each { |item| item.void(reason) }
  end

  private

  def set_program_id
    self.program_id ||= User.current&.program&.program_id
  end
end
