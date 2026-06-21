# frozen_string_literal: true

class OrderType < RetirableRecord
  self.table_name = :order_type
  self.primary_key = :order_type_id

  has_many :orders

  def self.find_by_name(name)
    return if name.blank?

    where('LOWER(name) = ?', name.to_s.downcase).first
  end
end
