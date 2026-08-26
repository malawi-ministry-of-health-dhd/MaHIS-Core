# frozen_string_literal: true

require 'json'
require 'rest-client'
require 'yaml'

module Api
  module V1
    class MiumConfigurationsController < ApplicationController
      skip_before_action :authenticate, only: :show

      def show
        config = mium_config

        response.headers['Cache-Control'] = 'no-store'
        return render json: { configured: false } if config[:url].blank?

        render json: {
          configured: true,
          miumURL: normalize_mium_url(config[:url])
        }
      end

      def token
        config = mium_config
        # MIUM usually runs on this same host, so the server-to-server login uses
        # token_url (e.g. http://127.0.0.1:4000/api) when configured. Going back out
        # through the public hostname makes the server depend on its own front door
        # and DNS, which is what made this time out in production.
        login_base_url = config[:token_url].presence || config[:url]

        response.headers['Cache-Control'] = 'no-store'
        unless login_base_url.present? && config[:username].present? && config[:password].present?
          return render json: { errors: ['MIUM is not configured'] }, status: :service_unavailable
        end

        login_response = RestClient::Request.execute(
          method: :post,
          url: build_mium_url(login_base_url, 'auth/login'),
          payload: { username: config[:username], password: config[:password] }.to_json,
          headers: { content_type: :json, accept: :json },
          # Split so the whole login attempt cannot exceed 5 seconds: the client
          # waits on this call during sign-in, so it must fail fast.
          open_timeout: 2,
          read_timeout: 3
        )

        login_payload = JSON.parse(login_response.body)
        unless login_payload['access_token'].present?
          error = login_payload['error'].presence || 'MIUM login did not return an access token'
          # Bad_gateway (not unauthorized): this is a failure of OUR upstream MIUM
          # service credentials, not the MaHIS user's session. The MaHIS client
          # treats any 401 as its own session expiry and clears the stored EMR
          # apiKey, which would log the user out mid-login.
          return render json: { errors: [error] }, status: :bad_gateway
        end

        render json: login_payload, status: :ok
      rescue RestClient::Unauthorized
        # See note above: surface bad MIUM service credentials as a gateway error,
        # never 401, so the MaHIS client does not clear the EMR session.
        render json: { errors: ['MIUM service credentials are invalid'] }, status: :bad_gateway
      # Must precede the ExceptionWithResponse rescue below: rest-client's timeouts
      # subclass RequestTimeout (an HTTP 408 class), so a later clause never runs and
      # a connect timeout used to report as a bare class name with no response code.
      rescue SocketError, Errno::ECONNREFUSED, RestClient::Exceptions::OpenTimeout,
             RestClient::Exceptions::ReadTimeout => e
        render json: { errors: ["MIUM is unreachable: #{e.message}"] }, status: :bad_gateway
      rescue RestClient::ExceptionWithResponse => e
        render json: { errors: ["MIUM login failed: #{e.response&.code || e.class}"] },
               status: :bad_gateway
      rescue JSON::ParserError
        render json: { errors: ['MIUM returned an invalid login response'] }, status: :bad_gateway
      end

      private

      def mium_config
        config = application_config
        nested = config['mium'].is_a?(Hash) ? config['mium'] : {}

        {
          url: ENV['MIUM_URL'].presence || config['MIUM_URL'].presence || nested['url'].presence,
          # Optional internal address used only by #token. Falls back to :url when
          # unset, so existing deployments keep working unchanged.
          token_url: ENV['MIUM_TOKEN_URL'].presence || config['MIUM_TOKEN_URL'].presence || nested['token_url'].presence,
          username: ENV['MIUM_USERNAME'].presence || config['MIUM_USERNAME'].presence || nested['username'].presence,
          password: ENV['MIUM_PASSWORD'].presence || config['MIUM_PASSWORD'].presence || nested['password'].presence
        }
      end

      def application_config
        YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')), aliases: true) || {}
      end

      def normalize_mium_url(url)
        url.to_s.sub(%r{/auth/login/?\z}, '').sub(%r{/+\z}, '')
      end

      def build_mium_url(base_url, resource_path)
        "#{normalize_mium_url(base_url)}/#{resource_path.to_s.sub(%r{\A/+}, '')}"
      end
    end
  end
end
