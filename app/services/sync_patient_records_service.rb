# frozen_string_literal: true

module SyncPatientRecordsService
  class << self
    include ModelUtils

    def get_not_sync_ids(ids)
      location_id = User.current.location_id
      
      query = PatientIdentifier
              .joins(patient: :encounters)
              .where(encounters: { location_id: location_id })
              .where('patient_identifier.identifier_type = ?', 3)
              .distinct

      return query.pluck(:patient_id) if ids.blank?

      query
        .where.not(identifier: ids)
        .pluck(:patient_id)
    end
  end
end