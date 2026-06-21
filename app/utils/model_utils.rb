# frozen_string_literal: true

# This module contains utility methods for retrieving models
module ModelUtils
  # Retrieve concept by its name
  #
  # Parameters:
  #  name - A string repr of the concept name
  def concept(*args)
    if args.empty?
      Rails.logger.error("CONCEPT_DEBUG: called with 0 args from:\n#{caller[0..15].join("\n")}")
      raise ArgumentError, "concept: wrong number of arguments (given 0, expected 1). See CONCEPT_DEBUG in log."
    end
    name = args.first
    return unless name.present?

    Concept.find_by_name(name)
  end

  def concept_name(name)
    return if name.blank?

    ConceptName.where('LOWER(name) = ?', name.to_s.downcase).first
  end

  def concept_name_to_id(name)
    return nil if name.blank?

    concept_name(name)&.concept_id
  end

  def concept_id_to_name(id)
    return nil if id.blank?

    concept = Concept.find_by_concept_id(id)
    concept&.fullname
  end

  def program(name)
    Program.find_by_name(name)
  end

  def encounter_type(name)
    EncounterType.find_by_name(name)
  end

  def global_property(name, location_id = nil)
    location_id = location_id || User.current.location_id
    GlobalProperty.unscoped.find_by property: name, location_id: location_id
  end

  def user_property(name, user_id: nil)
    user_id ||= User.current.user_id
    UserProperty.find_by(user_id:, property: name)
  end

  def order_type(name)
    OrderType.find_by_name(name)
  end

  def report_type(name)
    ReportType.find_by_name(name)
  end

  def patient_identifier_type(name)
    PatientIdentifierType.find_by_name(name)
  end

  def drug(name)
    Drug.find_by_name(name)
  end
end
