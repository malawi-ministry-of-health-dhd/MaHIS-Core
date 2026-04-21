require 'cgi'

module Api
  module V1
    class FhirController < ApplicationController
      APP_CONFIG = YAML.safe_load(File.read('config/application.yml'))
      BASE_FHIR_URL = APP_CONFIG['BASE_FHIR_URL'] # change to your HAPI FHIR URL

      SYNC_STATUS_TAG = 'ichis-mahis-pending'.freeze
      ICHIS_IDENTIFIER_SYSTEM = APP_CONFIG.fetch('ICHIS_IDENTIFIER_SYSTEM', 'https://ichis.org/ichisGeneratedID').freeze
      DHIS2_TEI_IDENTIFIER_SYSTEM = APP_CONFIG.fetch('DHIS2_TEI_IDENTIFIER_SYSTEM', 'https://dhis2.org/trackedEntityInstance').freeze

      def patients
        response = RestClient.get("#{BASE_FHIR_URL}/Patient", accept: 'application/fhir+json')
        render json: JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        render json: { error: e.message, response: e.response }, status: :bad_request
      end

      def patient
        patient_id = params[:id]
        bundle = find_patient_bundle(patient_id)

        if bundle && bundle['entry'].present?
          render json: bundle
          return
        end

        render json: { errors: ["Patient/#{patient_id} not found"] }, status: :not_found
      rescue RestClient::ExceptionWithResponse => e
        render json: { errors: ["Patient/#{patient_id} not found"], response: e.response }, status: :not_found
      end


      def observations
        requested_id = params[:id]

        patient_bundle = find_patient_bundle(requested_id)
        resolved_patient_id = extract_patient_id_from_bundle(patient_bundle) || requested_id

        bundle = fetch_first_non_empty(
          [
            "#{BASE_FHIR_URL}/Observation?subject=Patient/#{CGI.escape(resolved_patient_id)}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
            "#{BASE_FHIR_URL}/Observation?subject=Patient/#{CGI.escape(resolved_patient_id)}"
          ],
          allow_empty_fallback: true
        )

        render json: bundle
      rescue RestClient::ExceptionWithResponse => e
        render json: { errors: ["Observations for Patient/#{requested_id} not found"], response: e.response }, status: :not_found
      end

      private

      def fetch_json(url)
        response = RestClient.get(url, accept: 'application/fhir+json')
        JSON.parse(response.body)
      end

      def fetch_first_non_empty(urls, allow_empty_fallback: false)
        last_response = nil

        urls.each do |url|
          current = fetch_json(url)
          last_response = current
          return current if current.is_a?(Hash) && current['entry'].present?
        end

        allow_empty_fallback ? (last_response || { 'resourceType' => 'Bundle', 'entry' => [] }) : nil
      end

      def patient_search_urls(patient_id)
        escaped_id = CGI.escape(patient_id.to_s)

        [
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(ICHIS_IDENTIFIER_SYSTEM)}|#{escaped_id}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(DHIS2_TEI_IDENTIFIER_SYSTEM)}|#{escaped_id}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
          "#{BASE_FHIR_URL}/Patient?_id=#{escaped_id}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(ICHIS_IDENTIFIER_SYSTEM)}|#{escaped_id}",
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(DHIS2_TEI_IDENTIFIER_SYSTEM)}|#{escaped_id}",
          "#{BASE_FHIR_URL}/Patient?_id=#{escaped_id}"
        ]
      end

      def find_patient_bundle(patient_id)
        fetch_first_non_empty(patient_search_urls(patient_id))
      end

      def extract_patient_id_from_bundle(bundle)
        return nil unless bundle.is_a?(Hash)

        patient_entry = Array(bundle['entry']).find do |entry|
          entry.dig('resource', 'resourceType') == 'Patient'
        end

        patient_entry&.dig('resource', 'id')
      end
    end
  end
end
