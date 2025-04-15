class PatientSyncService
  def self.schedule_full_sync(location_id, since_date = nil)
    BatchPatientSyncJob.perform_async(location_id, since_date)
  end
  
  def self.schedule_sync_for_patient(patient_id, options = {})
    PatientRecordSyncJob.perform_async(patient_id, options)
  end
end