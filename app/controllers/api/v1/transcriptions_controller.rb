# frozen_string_literal: true

module Api
  module V1
    # Transcribes a dictated recording for the browser build.
    #
    # Only the web app posts here. The desktop and Android builds carry their own
    # speech model and never contact the server for dictation, which keeps their
    # audio on the device entirely.
    #
    # The transcript is a draft: the clinician reads and corrects it before
    # anything is saved. Nothing is persisted by this endpoint.
    class TranscriptionsController < ApplicationController
      def create
        text = TranscriptionService.transcribe(params[:audio])
        render json: { text: }
      rescue TranscriptionService::TranscriptionError => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      end
    end
  end
end
