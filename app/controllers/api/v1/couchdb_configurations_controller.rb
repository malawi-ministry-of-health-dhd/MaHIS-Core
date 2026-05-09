# frozen_string_literal: true

require 'yaml'
require Rails.root.join('lib', 'couchdb_url').to_s

module Api
  module V1
    class CouchdbConfigurationsController < ApplicationController
      def show
        couchdb_url = application_config['COUCHDB_URL'].to_s.strip

        response.headers['Cache-Control'] = 'no-store'
        return render json: { configured: false } if couchdb_url.blank?

        uri = URI.parse(couchdb_url)
        username, password = CouchdbUrl.credentials(couchdb_url)
        path = uri.path.to_s.gsub(%r{/+\z}, '')

        render json: {
          configured: true,
          couchdbProtocol: uri.scheme,
          couchdbHost: uri.host,
          couchdbPort: CouchdbUrl.explicit_port?(couchdb_url, uri) ? uri.port.to_s : '',
          couchdbPath: path == '/' ? '' : path,
          couchdbUsername: username.to_s,
          couchdbPassword: password.to_s
        }
      rescue URI::InvalidURIError => e
        render json: { configured: false, errors: ["Invalid CouchDB URL: #{e.message}"] }, status: :unprocessable_entity
      end

      private

      def application_config
        YAML.safe_load(File.read(Rails.root.join('config', 'application.yml')), aliases: true) || {}
      end
    end
  end
end
