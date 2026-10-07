# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/swagger_controller_contract')
require Rails.root.join('lib/swagger_open_api_normalizer')
require 'yaml'

RSpec.describe SwaggerControllerContract do
  def contract(method, path, action)
    described_class.new(method:, path:, action:).operation
  end

  it 'documents required and conditional location fields from the controller' do
    operation = contract('post', '/api/v1/locations', 'api/v1/locations#create')
    schema = operation.dig('requestBody', 'content', 'application/json', 'schema')

    expect(schema['required']).to contain_exactly('tag', 'name')
    expect(schema.dig('properties', 'parent_id', 'description')).to eq('Required in some branches.')
    expect(operation['responses'].keys).to include('200', '400', '403', '422')
  end

  it 'finds request fields in called parameter helpers' do
    operation = contract('post', '/api/v1/beds', 'api/v1/beds#create')
    properties = operation.dig('requestBody', 'content', 'application/json', 'schema', 'properties')

    expect(properties.keys).to include('bed_number', 'section_id', 'bed_type')
    expect(operation['responses']).to have_key('201')
  end

  it 'documents nested strong parameters' do
    operation = contract('post', '/api/v1/orders', 'api/v1/orders#create')
    schema = operation.dig('requestBody', 'content', 'application/json', 'schema')

    expect(schema['required']).to include('order')
    expect(schema.dig('properties', 'order', 'properties').keys).to include('concept_id', 'encounter_id')
  end

  it 'finds required report fields in the service helper' do
    operation = contract('get', '/api/v1/programs/{program_id}/reports/registration', 'api/v1/reports#registration')

    expect(operation['parameters'].filter_map { |item| item['name'] if item['required'] })
      .to include('program_id', 'start_date', 'end_date', 'date')
  end

  it 'marks missing and explicitly unfinished actions as unavailable' do
    missing = contract('post', '/api/v1/facilities', 'api/v1/facilities#create')
    unfinished = contract('put', '/api/v1/appointments/{id}', 'api/v1/appointments#update')

    expect(missing['x-route-unavailable']).to be(true)
    expect(unfinished['x-route-unavailable']).to be(true)
    expect(unfinished['deprecated']).to be(true)
  end

  it 'documents legacy redirects and public proxy security' do
    redirect = contract('get', '/api/v1/people/{person_id}/names', '')
    proxy = contract('get', '/api/v1/icd/{icd_path}', 'icd11_proxy#forward')

    expect(redirect['responses']).to have_key('301')
    expect(proxy['security']).to eq([])
    expect(proxy['responses']).to have_key('502')
  end

  it 'records gem controller locations without the local Ruby installation path' do
    operation = contract('patch', '/api/v1/lab/orders/{order_id}', 'lab/orders#update')

    expect(operation['x-controller-source'])
      .to eq('gems/his_emr_api_lab-2.4.7/app/controllers/lab/orders_controller.rb:23')
  end

  it 'keeps every served route operation outside the route-only placeholder state' do
    %w[swagger/v1/swagger.yaml swagger/lab/v1/swagger.yaml].each do |filename|
      document = YAML.safe_load_file(Rails.root.join(filename), aliases: true)
      document.fetch('paths').each do |path, methods|
        inherited_parameters = methods.fetch('parameters', [])
        methods.each do |method, operation|
          next unless %w[get post put patch delete head options].include?(method)

          expect(operation['x-route-inventory']).to be_nil
          expect(operation['responses']).to be_a(Hash)
          names = (inherited_parameters + operation.fetch('parameters', []))
                  .filter_map { |item| item['name'] if item['in'] == 'path' }
          expect(path.scan(/\{([^}]+)\}/).flatten - names).to be_empty
        end
      end
    end
  end

  it 'normalizes rswag shorthand into valid OpenAPI schema structure' do
    operation = {
      'parameters' => [{ 'name' => 'date', 'in' => 'query', 'format' => 'date', 'schema' => { 'type' => 'date' } }],
      'requestBody' => { 'content' => { 'application/json' => { 'schema' => {
        'type' => 'object', 'properties' => { 'amount' => { 'type' => 'float', 'required' => true } }
      } } } },
      'responses' => { '200' => { 'description' => 'ok' } }
    }

    normalized = SwaggerOpenApiNormalizer.new.normalize_operation(operation)

    expect(normalized.dig('parameters', 0, 'schema')).to eq('type' => 'string', 'format' => 'date')
    expect(normalized.dig('requestBody', 'content', 'application/json', 'schema', 'required')).to eq(['amount'])
    expect(normalized.dig('requestBody', 'content', 'application/json', 'schema', 'properties', 'amount'))
      .to eq('type' => 'number', 'format' => 'float')
  end
end
