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

        response.headers['Cache-Control'] = 'no-store'
        unless config[:url].present? && config[:username].present? && config[:password].present?
          return render json: { errors: ['MIUM is not configured'] }, status: :service_unavailable
        end

        login_response = RestClient::Request.execute(
          method: :post,
          url: build_mium_url(config[:url], 'auth/login'),
          payload: { username: config[:username], password: config[:password] }.to_json,
          headers: { content_type: :json, accept: :json },
          open_timeout: 6,
          read_timeout: 10
        )

        login_payload = JSON.parse(login_response.body)
        unless login_payload['access_token'].present?
          error = login_payload['error'].presence || 'MIUM login did not return an access token'
          return render json: { errors: [error] }, status: :unauthorized
        end

        render json: login_payload, status: :ok
      rescue RestClient::Unauthorized
        render json: { errors: ['MIUM service credentials are invalid'] }, status: :unauthorized
      rescue RestClient::ExceptionWithResponse => e
        render json: { errors: ["MIUM login failed: #{e.response&.code || e.class}"] },
               status: :bad_gateway
      rescue JSON::ParserError
        render json: { errors: ['MIUM returned an invalid login response'] }, status: :bad_gateway
      rescue SocketError, Errno::ECONNREFUSED, RestClient::Exceptions::OpenTimeout, RestClient::Exceptions::ReadTimeout => e
        render json: { errors: ["MIUM is unreachable: #{e.message}"] }, status: :bad_gateway
      end

      private

      def mium_config
        config = application_config
        nested = config['mium'].is_a?(Hash) ? config['mium'] : {}

        {
          url: ENV['MIUM_URL'].presence || config['MIUM_URL'].presence || nested['url'].presence,
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
