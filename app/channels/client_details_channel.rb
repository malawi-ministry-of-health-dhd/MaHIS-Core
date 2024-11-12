class ClientDetailsChannel < ApplicationCable::Channel

    def subscribed
        location_id = params[:location_id]

        stream_from "client_details_channel_#{location_id}"
    end

    def unsubscribed

    end
end