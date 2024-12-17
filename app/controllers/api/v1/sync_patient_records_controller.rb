
class Api::V1::SyncPatientRecordsController < ApplicationController
      
  def get_not_sync_ids
    previous_sync_date = params[:previous_sync_date]
    enable_site_sync = params[:enable_site_sync]
    records = SyncPatientRecordsService.get_not_sync_ids(previous_sync_date, enable_site_sync)
    render json: records, status: :ok
   
  end
 
  private

  def service
    SyncPatientRecordsService
  end

end