module Api
  module V1
    class FhirController < ApplicationController
      BASE_FHIR_URL = YAML.safe_load(File.read('config/application.yml'))['BASE_FHIR_URL'] # change to your HAPI FHIR URL

      def patients
        response = RestClient.get("#{BASE_FHIR_URL}/Patient", accept: 'application/fhir+json')
        render json: JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        render json: { error: e.message, response: e.response }, status: :bad_request
      end

      def patient
        patient_id = params[:id]
        response = RestClient.get("#{BASE_FHIR_URL}/Patient?identifier=https://ichis.org/ichisGeneratedID|#{patient_id}&_tag=ichis-mahis-pending", accept: 'application/fhir+json')
        render json: JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        render json: { error: "Patient/#{patient_id} not found", response: e.response }, status: :not_found
      end

      
      def observations
        patient_id = params[:id]
        url = "#{BASE_FHIR_URL}/Observation?subject=Patient/#{patient_id}&_tag=ichis-mahis-pending"
        response = RestClient.get(url, accept: 'application/fhir+json')
        render json: JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        render json: { error: "Observations for Patient/#{patient_id} not found", response: e.response }, status: :not_found
      end
    end
  end
end