# frozen_string_literal: true
module SyncPatientRecordsService
  class << self
    include ModelUtils
    def get_not_sync_ids(previous_sync_date = nil, enable_site_sync = nil)
      location_id = User.current.location_id
      
      query = Encounter.where('encounter.location_id = ?', location_id)
      query = query.where('encounter.date_created BETWEEN ? AND ?', 
                         previous_sync_date, 
                         Time.now.strftime("%Y-%m-%d %H:%M:%S")) if previous_sync_date.present?
      
      latest_encounter_datetime = query.maximum('encounter.date_created')
      
      {
        not_synced_ids: query.distinct.pluck(:patient_id),
        latest_encounter_datetime: latest_encounter_datetime
      }
    end
  end
end