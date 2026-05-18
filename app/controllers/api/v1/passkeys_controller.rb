# frozen_string_literal: true

module Api
  module V1
    class PasskeysController < ApplicationController
      skip_before_action :authenticate, only: %i[register authenticate]

      def register
        session_token, credential = params.require(%i[session_token credential])
        passkey = PasskeyAuthenticationService.register(
          session_token:,
          credential: credential.to_unsafe_h,
          nickname: params[:nickname]
        )

        render json: login_response(passkey.user, UserService.new_authentication_token(passkey.user)), status: :ok
      rescue ActiveRecord::RecordNotFound, WebAuthn::Error => e
        render json: { errors: [e.message] }, status: :unauthorized
      end

      def authenticate
        session_token, credential = params.require(%i[session_token credential])
        user = PasskeyAuthenticationService.authenticate(
          session_token:,
          credential: credential.to_unsafe_h
        )

        render json: login_response(user, UserService.new_authentication_token(user)), status: :ok
      rescue ActiveRecord::RecordNotFound, WebAuthn::Error => e
        render json: { errors: [e.message] }, status: :unauthorized
      end

      private

      def login_response(user, api_key)
        LoginResponseService.build(user, api_key)
      end
    end
  end
end
