# frozen_string_literal: true

class PatientIdentifierType < RetirableRecord
  self.table_name = :patient_identifier_type
  self.primary_key = :patient_identifier_type_id

  NPID_TYPE_NAME = 'National id'
  DDE_ID_TYPE_NAME = 'DDE person document id'

  NCD_NUMBER_TYPE_NAME = 'NCD Number'
  # Canonical id used as a fallback. The metadata seeds this type at id 31 and
  # several call sites historically hard-code it.
  NCD_NUMBER_TYPE_ID = 31

  # Resolves the "NCD Number" identifier type.
  #
  # The seeded metadata stores identifier-type names in sentence case
  # ("Ncd number") while the `name` column uses a case-sensitive (utf8_bin)
  # collation, so an exact-case `find_by_name('NCD Number')` never matches and
  # the lookup returns nil. Match case-insensitively, then fall back to the
  # canonical id so callers never get nil for a type that does exist.
  def self.ncd_number_type
    find_by('LOWER(name) = ?', NCD_NUMBER_TYPE_NAME.downcase) ||
      find_by(patient_identifier_type_id: NCD_NUMBER_TYPE_ID)
  end

  # Convenience accessor returning just the id, guaranteed non-nil.
  def self.ncd_number_type_id
    ncd_number_type&.patient_identifier_type_id || NCD_NUMBER_TYPE_ID
  end

  def next_identifier(options = {})
    return nil unless name == 'National id'

    new_national_id = options[:identifier].presence || (use_moh_national_id ? new_national_id(options) : new_v1_id(options))

    patient_identifier = PatientIdentifier.new
    patient_identifier.type = self
    patient_identifier.identifier = new_national_id
    patient_identifier.patient = options[:patient]
    location_id = options[:location_id].presence || current_location_id
    raise InvalidParameterError, 'Unable to resolve current location for identifier creation' if location_id.blank?

    patient_identifier.location_id = location_id
    patient_identifier.save if patient_identifier.patient
    patient_identifier
  end

  def next_identifier_for_malawi_nid(options = {})
    return nil unless name == 'Malawi National ID'

    new_national_id = options[:MNID]

    patient_identifier = PatientIdentifier.new
    patient_identifier.type = self
    patient_identifier.identifier = new_national_id.upcase
    patient_identifier.patient = options[:patient]
    location_id = options[:location_id].presence || current_location_id
    raise InvalidParameterError, 'Unable to resolve current location for identifier creation' if location_id.blank?

    patient_identifier.location_id = location_id
    patient_identifier.save if patient_identifier.patient
    patient_identifier
  end

  private

  def use_moh_national_id
    property = GlobalProperty.find_by_property('use.moh.national.id')
    property.property_value == 'yes'
  rescue StandardError => e
    Rails.logger.error "Suppressed error: #{e}"
    false
  end

  def new_national_id(options = {})
    NationalId.next_id(options[:patient]&.patient_id)
  end

  def new_v1_id(options = {})
    id_prefix = v1_id_prefix(options[:location_id])
    last_identifier = last_id_number(id_prefix)
    next_number = (last_identifier[id_prefix.size..-2].to_i + 1).to_s.rjust(7, '0')
    new_national_id_no_check_digit = "#{id_prefix}#{next_number}"
    check_digit = PatientIdentifier.calculate_checkdigit(
      new_national_id_no_check_digit[1..]
    )
    "#{new_national_id_no_check_digit}#{check_digit}"
  end

  def v1_id_prefix(location_id = nil)
    location = if location_id
                 Location.find_by(location_id:)
               else
                 Location.current || Location.current_health_center
               end

    health_center_id = location&.site_id.to_s.rjust(3, '0')
    "P1#{health_center_id}"
  end

  def last_id_number(id_prefix)
    PatientIdentifier.where(
      'identifier_type = ? AND left(identifier, ?) = ?',
      patient_identifier_type_id, id_prefix.size, id_prefix
    ).order(identifier: :desc).first&.identifier || '0'
  end

  def current_location_id
    (Location.current || Location.current_health_center)&.location_id
  end
end
