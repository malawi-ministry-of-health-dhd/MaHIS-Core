# frozen_string_literal: true

class ArtNumberSequence < ApplicationRecord
  self.table_name = :art_number_sequence

  validates :location_id, :site_prefix, presence: true
  validates :location_id, uniqueness: true

  def self.cohort_baseline(location_id, site_prefix)
    pattern = /\A#{Regexp.escape(site_prefix)}-ARV-(\d+)\z/
    arv_type_id = PatientIdentifierType.find_by!(name: 'ARV Number').id

    PatientIdentifier.unscoped
                     .where(identifier_type: arv_type_id, location_id:, voided: false)
                     .pluck(:identifier)
                     .count { |identifier| identifier.to_s.match?(pattern) }
  end

  def self.next_available(location_id, site_prefix)
    transaction do
      counter = find_or_initialize_counter(location_id, site_prefix)
      next_sequence = counter.last_sequence.to_i + 1
      used_sequences = assigned_sequences(location_id, site_prefix)
      next_sequence += 1 while used_sequences.include?(next_sequence)
      next_sequence
    end
  end

  def self.advance_if_next(location_id, site_prefix, sequence)
    transaction do
      counter = find_or_initialize_counter(location_id, site_prefix)
      candidate = counter.last_sequence.to_i + 1
      used_sequences = assigned_sequences(location_id, site_prefix).reject { |used| used == sequence.to_i }
      candidate += 1 while used_sequences.include?(candidate)

      if candidate == sequence.to_i
        counter.update!(last_sequence: candidate)
      end
    end
  end

  def self.find_or_initialize_counter(location_id, site_prefix)
    counter = lock.find_or_initialize_by(location_id: location_id)
    counter.site_prefix = site_prefix
    if counter.new_record? || counter.last_sequence.to_i.zero?
      counter.last_sequence = [counter.last_sequence.to_i, cohort_baseline(location_id, site_prefix)].max
    end
    counter.save! if counter.new_record? || counter.changed?
    counter
  end

  def self.assigned_sequences(location_id, site_prefix)
    pattern = /\A#{Regexp.escape(site_prefix)}-ARV-(\d+)\z/
    arv_type_id = PatientIdentifierType.find_by!(name: 'ARV Number').id

    PatientIdentifier.unscoped
                     .where(identifier_type: arv_type_id, location_id: location_id)
                     .pluck(:identifier)
                     .filter_map { |identifier| identifier.to_s.match(pattern)&.[](1)&.to_i }
                     .uniq
  end
end
