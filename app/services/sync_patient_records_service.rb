# frozen_string_literal: true

module SyncPatientRecordsService
  class << self
    include ModelUtils
    def get_not_sync_ids(ids)
      location_id = User.current.location_id
      PatientIdentifier.joins('INNER JOIN encounter USING (patient_id)')
             .where('identifier NOT IN (?) AND encounter.location_id = ?', ids, location_id).distinct 
             .pluck(:patient_id)
    end
  end
end
