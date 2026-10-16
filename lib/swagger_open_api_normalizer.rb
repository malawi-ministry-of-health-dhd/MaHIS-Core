# frozen_string_literal: true

# Repairs rswag output that uses schema shorthand OpenAPI 3 does not accept.
# The corrections are structural only: parameter formats/defaults move into
# schemas, schema scalar types become OpenAPI types, and nested required flags
# become parent required lists.
class SwaggerOpenApiNormalizer
  SCHEMA_KEYS = %w[type format properties items required enum description example default nullable readOnly writeOnly
                   additionalProperties oneOf anyOf allOf not minimum maximum minLength maxLength minItems maxItems
                   pattern uniqueItems].freeze
  def normalize_operation(operation)
    copy = Marshal.load(Marshal.dump(operation))
    Array(copy['parameters']).each { |parameter| normalize_parameter(parameter) }
    copy.fetch('responses', {}).each_value do |response|
      response.fetch('content', {}).each_value { |media| normalize_schema(media['schema']) }
    end
    copy.fetch('requestBody', {}).fetch('content', {}).each_value { |media| normalize_schema(media['schema']) }
    copy
  end

  private

  def normalize_parameter(parameter)
    return unless parameter.is_a?(Hash)

    schema = parameter['schema'] ||= {}
    %w[format default].each do |key|
      schema[key] = parameter.delete(key) if parameter.key?(key)
    end
    normalize_schema(schema)
  end

  def normalize_schema(schema)
    return unless schema.is_a?(Hash)

    case schema['type']
    when 'float'
      schema['type'] = 'number'
      schema['format'] ||= 'float'
    when 'date'
      schema['type'] = 'string'
      schema['format'] ||= 'date'
    when 'datetime'
      schema['type'] = 'string'
      schema['format'] ||= 'date-time'
    when 'file'
      schema['type'] = 'string'
      schema['format'] ||= 'binary'
    end

    properties = schema['properties']
    if properties.is_a?(Hash)
      # Some rswag examples put a second schema inside `properties`.
      if properties['type'].is_a?(String) && properties['properties'].is_a?(Hash)
        schema['type'] = properties['type']
        schema['required'] = properties['required'] if properties['required'].is_a?(Array)
        schema['properties'] = properties = properties['properties']
      elsif properties['required'].is_a?(Array)
        schema['required'] = properties.delete('required')
      end

      required = Array(schema['required'])
      properties.each do |name, property|
        next unless property.is_a?(Hash)

        if property.keys.none? { |key| SCHEMA_KEYS.include?(key) || key.start_with?('x-') } &&
           property.values.all? { |value| value.is_a?(Hash) }
          property = properties[name] = { 'type' => 'object', 'properties' => property }
        end

        flag = property['required']
        if flag == true || flag == false
          property.delete('required')
          required << name if flag
        end
        normalize_schema(property)
      end
      schema['required'] = required.uniq unless required.empty?
    end

    normalize_schema(schema['items'])
    %w[oneOf anyOf allOf].each do |key|
      Array(schema[key]).each { |variant| normalize_schema(variant) }
    end
    normalize_schema(schema['additionalProperties'])
  end
end
