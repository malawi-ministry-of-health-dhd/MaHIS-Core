# frozen_string_literal: true

class DrugCms < VoidableRecord
  self.table_name = :drug_cms
  self.primary_key = :id

  belongs_to :drug, foreign_key: :drug_inventory_id
  belongs_to :program, foreign_key: :program_id, primary_key: :program_id, optional: true
  belongs_to :location, foreign_key: :location_id, primary_key: :location_id, optional: true
  
  validates :name, presence: true, uniqueness: { scope: [:program_id, :location_id] }
  validates :short_name, uniqueness: { scope: [:program_id, :location_id], allow_blank: true }
  validates :code, presence: true, uniqueness: { scope: [:program_id, :location_id] }
  validates :pack_size, presence: true, numericality: { only_integer: true, greater_than: 0 }
  
  # Scopes for filtering
  scope :for_program, ->(program_id) { where(program_id: program_id) if program_id.present? }
  scope :for_location, ->(location_id) { where(location_id: location_id) if location_id.present? }
end
