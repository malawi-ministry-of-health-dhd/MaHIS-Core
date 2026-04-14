class ClientDetailsChannel < ApplicationCable::Channel

    def subscribed
        location_id = params[:location_id]
        program_id = params[:program_id]

        stream_from "client_details_channel_#{location_id}"
        transmit_stage_snapshot(location_id, program_id) if program_id.present?
    end

    def unsubscribed

    end

    private

    def transmit_stage_snapshot(location_id, program_id = nil)
        return if location_id.blank?

        stages_service = StagesService.new
        scope = stages_service.active_stages(location_id)
        scope = scope.where(program_id: program_id) if program_id.present?

        data = scope.map { |stage| stages_service.serialize(stage) }

        transmit(
            event: "stages_snapshot",
            data: data
        )
    rescue StandardError => e
        Rails.logger.error("ClientDetailsChannel snapshot error: #{e.message}")
    end
end
