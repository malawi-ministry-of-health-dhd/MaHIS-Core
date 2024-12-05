# frozen_string_literal: true

module SyncPatientRecordsService
  class << self
    include ModelUtils

    def get_not_sync_ids(previous_sync_date = nil, enable_site_sync= nil)
      location_id = User.current.location_id
      query = PatientIdentifier
              .joins(patient: :encounters)
              .where('patient_identifier.identifier_type = ?', 3)
              .distinct
      query= query.where(encounters: { location_id: location_id }) if enable_site_sync.present?
      query = query.where('encounter.encounter_datetime BETWEEN ? AND ?', previous_sync_date, Time.now.strftime("%Y-%m-%d %H:%M:%S")) if previous_sync_date.present?
      latest_encounter_datetime = query.maximum('encounter.encounter_datetime')
      {
        not_synced_ids: query.pluck(:patient_id),
        latest_encounter_datetime: latest_encounter_datetime
      }
    end
  end
end
