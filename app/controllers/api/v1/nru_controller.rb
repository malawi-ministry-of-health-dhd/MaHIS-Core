module Api
  module V1
    class NruController < ApplicationController
      before_action :authenticate

      def dashboard
        program_id = params.require(:program_id)
        date       = params[:date]&.to_date || Date.today
        service    = NruService.new(program_id: program_id)
        render json: service.dashboard(date: date)
      end
    end
  end
end