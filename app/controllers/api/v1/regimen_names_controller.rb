# frozen_string_literal: true

module Api
  module V1
    class RegimenNamesController < ApplicationController
      def index
        render json: service.find_all
      end

      private

      def service
        @service ||= RegimenNameService.new
      end
    end
  end
end
