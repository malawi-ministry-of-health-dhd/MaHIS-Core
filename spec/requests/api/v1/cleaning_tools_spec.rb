# frozen_string_literal: true

require 'swagger_helper'

TAGS_NAME = 'Cleaning Tools'

describe 'Cleaning Tools API', type: :request, swagger_doc: 'v1/swagger.yaml' do
  path '/api/v1/art_data_cleaning_tools' do
    get 'Retrieve patients with data problems' do
      tags TAGS_NAME
      description 'This shows the patients with data problems'
      produces 'application/json'
      security [api_key: []]
      parameter name: :program_id, in: :query, required: true, schema: { type: :integer }
      parameter name: :start_date, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :report_name, in: :query, required: true, schema: { type: :string }
      parameter name: :page, in: :query, schema: { type: :integer }
      parameter name: :per_page, in: :query, schema: { type: :integer }

      response '200', 'Report-specific data, a paginated data/meta object, or an error string' do
        schema oneOf: [
          { type: :array, items: { type: :object, additionalProperties: true } },
          { type: :object, additionalProperties: true },
          { type: :string }
        ]
        run_test!
      end
    end
  end

  path '/api/v1/void_multiple_identifiers' do
    delete 'Void multiple filing numbers' do
      tags TAGS_NAME
      description 'This voids multiple filing numbers'
      consumes 'application/json'
      security [api_key: []]
      # request body
      parameter name: :params, in: :body, schema: {
        type: :object,
        properties: {
          identifiers: { type: :array, items: { type: :integer } },
          reason: { type: :string }
        },
        required: %w[identifiers]
      }

      response '204', 'Returns no content' do
        let(:params) { { identifiers: [{ identifier: 'FN10100001', patient_id: 347 }], reason: 'Testing voiding' } }
        run_test!
      end
    end
  end
end
