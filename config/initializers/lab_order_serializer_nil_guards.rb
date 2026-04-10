# frozen_string_literal: true

# Guard against nil specimen names when serializing lab orders for LIMS.
# Some records may have specimen concept IDs without a resolved display name.
module LabOrderSerializerNilGuards
  private

  def format_sample_type(name)
    normalized = name.to_s.strip
    return 'not_specified' if normalized.empty? || normalized.casecmp?('Unknown')

    return 'CSF' if normalized.casecmp?('Cerebrospinal Fluid')

    normalized.titleize
  end

  def format_sample_status(name)
    normalized = name.to_s.strip
    return 'specimen_not_collected' if normalized.empty? || normalized.casecmp?('Unknown')

    'specimen_collected'
  end
end

Rails.application.config.to_prepare do
  serializer = 'Lab::Lims::OrderSerializer'.safe_constantize
  next unless serializer

  singleton = serializer.singleton_class
  singleton.prepend(LabOrderSerializerNilGuards) unless singleton < LabOrderSerializerNilGuards
end
