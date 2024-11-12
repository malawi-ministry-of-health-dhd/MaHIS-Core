class ClientDetailsJob < ApplicationJob
    queue_as :default

    def perform(location_id)
       client_details =  Patient.joins(:patient_programs).all.where("patient_program.location_id = ?", location_id)
       ActionCable.server.broadcast("client_details_channel_#{location_id}", client_details.as_json )
    end

end