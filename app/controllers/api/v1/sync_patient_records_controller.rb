
class Api::V1::SyncPatientRecordsController < ApplicationController
      
  def get_not_sync_ids
    ids = params[:ids]
    records = SyncPatientRecordsService.get_not_sync_ids(ids)
    render json: records, status: :ok
   
  end
 
  private

  def service
    SyncPatientRecordsService
  end

end