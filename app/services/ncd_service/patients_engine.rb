# frozen_string_literal: true

class NcdService::PatientsEngine
  include ModelUtils
  def initialize(program: nil)
    @program = program || Program.find_by_name!('NCD Program')
  end

  def visit_summary_label(patient, date)
    OPDService::VisitLabel.new(patient, date)
  end
  # Retrieves given patient's status info.
  #
  # The info is just what you would get on a patient information
  # confirmation page in an ART application.
  def patient(patient_id, date)
    patient_summary(Patient.find(patient_id), date).full_summary
  end

  def patient_summary(patient, date)
    PatientSummary.new patient, date
  end

  def find_next_available_ncd_number
    current_ncd_code = global_property("site_prefix")&.property_value
    raise 'Global property `site_prefix` not set' unless current_ncd_code

    "#{current_ncd_code} #{PatientIdentifier.next_available_ncd_number(current_ncd_code)}"
  end

  def ncd_number_already_exists(ncd_number)
    identifier_type = PatientIdentifierType.find_by_name('NCD Number')
    # `unscoped` so a voided number still reports as taken and is never reused.
    PatientIdentifier.unscoped.where(
      identifier: ncd_number,
      identifier_type: identifier_type.id
    ).exists?
  end

end
