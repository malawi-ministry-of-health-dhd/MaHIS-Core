# frozen_string_literal: true

class EncounterType < RetirableRecord
  self.table_name = :encounter_type
  self.primary_key = :encounter_type_id

  has_many :encounters

  HIV_CLINIC_CONSULTATION = 'HIV CLINIC CONSULTATION'
  HIV_CLINIC_REGISTRATION = 'HIV CLINIC REGISTRATION'
  REGISTRATION = 'REGISTRATION'

  def self.find_by_name(name)
    return if name.blank?

    where('LOWER(name) = ?', name.to_s.downcase).first
  end
end
