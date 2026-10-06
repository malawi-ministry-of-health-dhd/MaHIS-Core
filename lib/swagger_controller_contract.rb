# frozen_string_literal: true

# Builds a source-backed OpenAPI operation for routes without a hand-written
# rswag contract. It inspects the dispatched controller method, so a route with
# no action is never advertised as a working endpoint.
class SwaggerControllerContract
  STATUS_CODES = {
    ok: '200', created: '201', accepted: '202', no_content: '204',
    moved_permanently: '301', found: '302', bad_request: '400',
    unauthorized: '401', forbidden: '403', not_found: '404',
    conflict: '409', gone: '410', unprocessable_entity: '422',
    too_many_requests: '429', internal_server_error: '500', bad_gateway: '502',
    service_unavailable: '503'
  }.freeze
  METHODS_WITH_BODY = %w[post put patch delete].freeze
  RAILS_KEYS = %w[controller action format authenticity_token].freeze
  REDIRECTS = {
    '/api/v1/people/{person_id}/names' => ['/api/v1/people/_names', 'person_id'],
    '/api/v1/patients/{patient_id}/appointments' => ['/api/v1/appointments', 'patient_id'],
    '/api/v1/locations/{location_id}/label' => ['/api/v1/labels/location', 'location_id'],
    '/api/v1/regions/{region_id}/districts' => ['/api/v1/districts', 'region_id'],
    '/api/v1/districts/{district_id}/traditional_authorities' => ['/api/v1/traditional_authorities', 'district_id'],
    '/api/v1/traditional_authorities/{traditional_authority_id}/villages' => ['/api/v1/villages', 'traditional_authority_id'],
    '/api/v1/traditional_authorities/{traditional_authority_id}/villages/{village_id}' => ['/api/v1/villages/{village_id}', nil],
    '/api/v1/encounters/{encounter_id}/observations' => ['/api/v1/observations', 'encounter_id']
  }.freeze

  def initialize(route)
    @route = route
    @path = route.fetch(:path)
    @verb = route.fetch(:method)
    @action = route.fetch(:action).to_s
  end

  def operation
    return redirect_operation if REDIRECTS.key?(@path)

    controller_name, action_name = @action.split('#')
    return unavailable_operation if controller_name.nil? || action_name.nil?

    @controller = "#{controller_name.camelize}Controller".constantize
    return unavailable_operation unless @controller.action_methods.include?(action_name)

    @method = @controller.instance_method(action_name)
    @file, = @method.source_location
    return unavailable_operation unless @file

    @ast = RubyVM::AbstractSyntaxTree.of(@method)
    @lines = File.readlines(@file)
    if @lines[@ast.first_lineno - 1...@ast.last_lineno].join.include?("['Not implemented']")
      return unavailable_operation('The controller explicitly returns Not implemented.')
    end
    @fields = {}
    @nested_fields = {}
    @accepts_any_body = false
    @assignments = {}
    @renders = []
    scan(@ast)
    scan_parameter_helpers
    scan_delegates if @renders.empty?
    build_operation(action_name)
  rescue NameError, ArgumentError
    unavailable_operation
  end

  private

  def node?(value)
    value.is_a?(RubyVM::AbstractSyntaxTree::Node)
  end

  def children(node)
    node.children.select { |child| node?(child) }
  end

  def each_node(node, &block)
    return unless node?(node)

    yield node
    children(node).each { |child| each_node(child, &block) }
  end

  def list(node)
    return [] unless node?(node)
    return node.children.compact if node.type == :LIST

    [node]
  end

  def literal(node)
    return nil unless node?(node)

    return node.children.first if node.type == :LIT
    return true if node.type == :TRUE
    return false if node.type == :FALSE
    return nil if node.type == :NIL

    nil
  end

  def hash_pairs(node)
    return {} unless node?(node) && node.type == :HASH

    values = list(node.children.first)
    values.each_slice(2).each_with_object({}) do |(key, value), result|
      name = literal(key)
      result[name.to_s] = value if name
    end
  end

  def params_receiver?(node)
    node?(node) && %i[VCALL FCALL LVAR].include?(node.type) && node.children.first == :params
  end

  def literal_names(node, depth = 0)
    return [] unless node?(node)
    return [] if depth > 5

    if node.type == :HASH
      return hash_pairs(node).keys + hash_pairs(node).values.flat_map { |value| literal_names(value, depth + 1) }
    end
    if node.type == :LVAR
      assigned = @assignments[node.children.first]
      return literal_names(assigned, depth + 1) if assigned && assigned != node
    end
    if %i[CONST COLON2].include?(node.type)
      constant = constant_from_node(node)
      return constant.map(&:to_s) if constant.is_a?(Array) && constant.all? { |value| value.is_a?(String) || value.is_a?(Symbol) }
    end
    value = literal(node)
    return [value.to_s] if value.is_a?(Symbol) || value.is_a?(String)

    children(node).flat_map { |child| literal_names(child, depth + 1) }
  end

  def constant_from_node(node)
    name = if node.type == :CONST
             node.children.first.to_s
           elsif node.type == :COLON2
             parent, member = node.children
             "#{constant_name(parent)}::#{member}"
           end
    name&.constantize
  rescue NameError
    nil
  end

  def constant_name(node)
    return node.children.first.to_s if node?(node) && node.type == :CONST
    return "#{constant_name(node.children.first)}::#{node.children.last}" if node?(node) && node.type == :COLON2

    ''
  end

  def add_field(name, required: false, conditional: false, array: false)
    name = name.to_s
    return if name.empty? || RAILS_KEYS.include?(name)

    field = (@fields[name] ||= { required: false, conditional: false, array: false })
    field[:required] ||= required && !conditional
    field[:conditional] ||= required && conditional
    field[:array] ||= array
  end

  def scan(node, conditional = false)
    return unless node?(node)

    if %i[IF UNLESS CASE WHEN RESCUE].include?(node.type)
      node.children.each_with_index do |child, index|
        scan(child, conditional || index.positive?) if node?(child)
      end
      return
    end

    if node.type == :LASGN
      @assignments[node.children[0]] = node.children[1]
    end

    if node.type == :CALL && params_receiver?(node.children[0])
      method_name = node.children[1]
      arguments = list(node.children[2])
      case method_name
      when :[], :fetch, :dig, :include?, :key?, :delete
        name = literal(arguments.first)
        add_field(name) if name
      when :require
        arguments.flat_map { |arg| literal_names(arg) }.each do |name|
          add_field(name, required: true, conditional: conditional)
        end
      when :permit
        arguments.each do |argument|
          if node?(argument) && argument.type == :HASH
            hash_pairs(argument).each do |name, value|
              add_field(name, array: node?(value) && value.type == :LIST)
              nested = literal_names(value)
              @nested_fields[name] = nested unless nested.empty?
            end
          else
            literal_names(argument).each { |name| add_field(name) }
          end
        end
      when :permit!, :each, :to_unsafe_h
        @accepts_any_body = true
      end
    elsif node.type == :CALL && node.children[1] == :permit && node?(node.children[0])
      receiver = node.children[0]
      if receiver.type == :CALL && receiver.children[1] == :require && params_receiver?(receiver.children[0])
        parent = literal(list(receiver.children[2]).first)
        if parent
          add_field(parent, required: true, conditional: conditional)
          @nested_fields[parent.to_s] = list(node.children[2]).flat_map { |arg| literal_names(arg) }
        end
      end
    elsif node.type == :FCALL && node.children[0] == :required_params
      list(node.children[1]).each do |argument|
        hash_pairs(argument).fetch('required', nil)&.then do |value|
          literal_names(value).each { |name| add_field(name, required: true, conditional: conditional) }
        end
      end
    elsif node.type == :FCALL && node.children[0] == :render
      options = hash_pairs(list(node.children[1]).first)
      @renders << { options: options, source: node }
    elsif node.type == :FCALL && %i[head send_data send_file redirect_to].include?(node.children[0])
      @renders << { kind: node.children[0], source: node }
    end

    children(node).each { |child| scan(child, conditional) }
  end

  def path_parameters
    @path.scan(/\{([^}]+)\}/).flatten.map do |name|
      { 'name' => name, 'in' => 'path', 'required' => true,
        'description' => 'URL path segment; Rails passes it to the action as a string.',
        'schema' => { 'type' => 'string' } }
    end
  end

  def field_schema(name, array: false)
    return { 'type' => 'array', 'items' => field_schema(name.sub(/s\z/, '')) } if array || name.end_with?('_ids')
    return { 'type' => 'integer' } if name.match?(/(?:\A|_)(?:id|page|page_size|limit|offset|count|quantity|age)\z/)
    return { 'type' => 'string', 'format' => 'date-time' } if name.match?(/(?:datetime|_at)\z/)
    return { 'type' => 'string', 'format' => 'date' } if name.match?(/(?:\A|_)date\z/)

    { 'type' => 'string' }
  end

  def request_contract(operation)
    path_names = path_parameters.map { |entry| entry['name'] }
    fields = @fields.reject { |name, _| path_names.include?(name) || name == '_json' }
    operation['parameters'] = path_parameters

    if METHODS_WITH_BODY.include?(@verb)
      if @fields.key?('_json')
        schema = { 'type' => 'array', 'items' => { 'type' => 'object', 'additionalProperties' => true } }
        operation['requestBody'] = { 'required' => true, 'content' => { 'application/json' => { 'schema' => schema } } }
      elsif fields.any?
        properties = fields.to_h do |name, details|
          schema = if @nested_fields[name]
                     nested = @nested_fields.fetch(name)
                     if details[:array]
                       { 'type' => 'array', 'items' => { 'type' => 'object', 'properties' => nested.to_h { |field| [field, field_schema(field)] } } }
                     else
                       { 'type' => 'object', 'properties' => nested.to_h { |field| [field, field_schema(field)] } }
                     end
                   else
                     field_schema(name, array: details[:array])
                   end
          schema['description'] = 'Required in some branches.' if details[:conditional] && !details[:required]
          [name, schema]
        end
        schema = { 'type' => 'object', 'properties' => properties }
        required = fields.filter_map { |name, details| name if details[:required] }
        schema['required'] = required unless required.empty?
        operation['requestBody'] = {
          'required' => required.any?,
          'description' => 'Controller request parameters. Rails may also accept these in the query string.',
          'content' => { 'application/json' => { 'schema' => schema } }
        }
      elsif @accepts_any_body
        operation['requestBody'] = {
          'required' => false,
          'description' => 'The controller reads the request parameter hash without an explicit field allowlist.',
          'content' => { 'application/json' => { 'schema' => { 'type' => 'object', 'additionalProperties' => true } } }
        }
      end
    else
      operation['parameters'] += fields.map do |name, details|
        parameter = { 'name' => name, 'in' => 'query', 'required' => details[:required], 'schema' => field_schema(name, array: details[:array]) }
        parameter['description'] = 'Required in some branches.' if details[:conditional] && !details[:required]
        parameter
      end
    end
  end

  def response_status(node)
    return '200' if node.nil?

    value = literal(node)
    return STATUS_CODES.fetch(value, value.to_s) if value.is_a?(Symbol)
    return value.to_s if value.is_a?(Integer)
    if node?(node) && node.type == :LVAR && node.children.first == :success_response_status
      return @verb == 'post' ? '201' : '200'
    end

    'default'
  end

  def schema_for(node, depth = 0)
    return {} unless node?(node) && depth < 5

    case node.type
    when :HASH
      properties = hash_pairs(node).to_h do |key, value|
        [key, schema_for(value, depth + 1)]
      end
      { 'type' => 'object', 'properties' => properties }
    when :LIST, :ZLIST
      item = list(node).first
      { 'type' => 'array', 'items' => schema_for(item, depth + 1) }
    when :STR, :DSTR
      { 'type' => 'string' }
    when :TRUE, :FALSE
      { 'type' => 'boolean' }
    when :LIT
      value = literal(node)
      return { 'type' => 'integer' } if value.is_a?(Integer)
      return { 'type' => 'number' } if value.is_a?(Float)
      return { 'type' => 'string' } if value.is_a?(String) || value.is_a?(Symbol)
      {}
    when :LVAR
      assigned = @assignments[node.children[0]]
      assigned && assigned != node ? schema_for(assigned, depth + 1) : {}
    when :FCALL, :CALL
      method_name = node.type == :FCALL ? node.children[0] : node.children[1]
      return { 'type' => 'array', 'items' => {} } if %i[paginate collect map pluck to_a].include?(method_name)
      return { 'type' => 'object', 'additionalProperties' => true } if %i[as_json to_h to_hash].include?(method_name)
      return { 'type' => 'object', 'additionalProperties' => true } if %i[find find_by find_by! find_or_create_by create create! new first last].include?(method_name)
      return { 'type' => 'array', 'items' => { 'type' => 'object', 'additionalProperties' => true } } if %i[where all includes order joins preload limit offset distinct select group].include?(method_name)
      return { 'type' => 'boolean' } if method_name.to_s.end_with?('?')
      return { 'type' => 'integer' } if %i[count size length to_i].include?(method_name)
      return { 'type' => 'number' } if %i[sum to_f].include?(method_name)
      return { 'type' => 'string' } if %i[to_s to_json].include?(method_name)
      {}
    else
      {}
    end
  end

  def response_contract(operation)
    responses = {}
    if @renders.empty? && calls_method?(@ast, :render_zpl)
      responses['200'] = {
        'description' => 'Barcode or label data. Use raw=true for a printable label stream.',
        'content' => {
          'application/json' => { 'schema' => { 'type' => 'object', 'additionalProperties' => true } },
          'application/label' => { 'schema' => { 'type' => 'string', 'format' => 'binary' } }
        }
      }
      @fields['raw'] ||= { required: false, conditional: false, array: false }
      request_contract(operation)
    end
    @renders.each do |render|
      if render[:kind]
        status = case render[:kind]
                 when :head then response_status(list(render[:source].children[1]).first)
                 when :redirect_to then '302'
                 else '200'
                 end
        response = { 'description' => render[:kind] == :redirect_to ? 'Redirect.' : 'Response sent by controller.' }
        response['content'] = { 'application/octet-stream' => { 'schema' => { 'type' => 'string', 'format' => 'binary' } } } if %i[send_data send_file].include?(render[:kind])
      else
        options = render[:options]
        status = response_status(options['status'])
        json = options['json']
        response = { 'description' => json ? 'JSON response from the controller.' : 'Response from the controller.' }
        if json
          schema = schema_for(json)
          expression = origin_text(json)
          if schema.empty? && expression.length <= 180
            schema['description'] = "Serialized result of `#{expression}`. The output shape is defined by the called service."
          end
          response['description'] = if schema['properties']
                                      "JSON fields: #{schema['properties'].keys.join(', ')}."
                                    elsif schema['type'] == 'array'
                                      'JSON array returned by the controller.'
                                    else
                                      "Serialized JSON result of `#{expression}`."
                                    end
          response['content'] = { 'application/json' => { 'schema' => schema } }
        elsif options['body']
          response['description'] = 'Body and status forwarded from the upstream service.'
          response['content'] = { '*/*' => { 'schema' => { 'type' => 'string' } } }
        end
      end
      if responses.key?(status)
        merge_response!(responses[status], response)
      else
        responses[status] = response
      end
    end

    responses['204'] = { 'description' => 'Action completed without an explicit response body.' } if responses.empty?
    if @controller.ancestors.include?(ApplicationController) && !public_action?
      responses['401'] ||= {
        'description' => 'Authorization header is missing, invalid, or expired.',
        'content' => { 'application/json' => { 'schema' => { 'type' => 'object', 'properties' => {
          'errors' => { 'type' => 'array', 'items' => { 'type' => 'string' } }
        } } } }
      }
    end
    responses['400'] ||= { 'description' => 'A required request parameter is missing.' } if @fields.values.any? { |field| field[:required] }
    operation['responses'] = responses.sort.to_h
  end

  def merge_response!(existing, incoming)
    old_schema = existing.dig('content', 'application/json', 'schema')
    new_schema = incoming.dig('content', 'application/json', 'schema')
    return unless new_schema
    return existing['content'] = incoming['content'] unless old_schema
    return if old_schema == new_schema

    schemas = old_schema['oneOf'] || [old_schema]
    schemas << new_schema unless schemas.include?(new_schema)
    existing['content']['application/json']['schema'] = { 'oneOf' => schemas }
  end

  def source_text(node)
    first_line = @lines[node.first_lineno - 1]
    return '' unless first_line
    return first_line[node.first_column...node.last_column].to_s.strip if node.first_lineno == node.last_lineno

    first_line[node.first_column..].to_s.strip.gsub(/\s+/, ' ')[0, 160]
  end

  def origin_text(node, depth = 0)
    return source_text(node) unless node?(node) && node.type == :LVAR && depth < 3

    assigned = @assignments[node.children.first]
    assigned ? origin_text(assigned, depth + 1) : source_text(node)
  end

  def calls_method?(node, name)
    found = false
    each_node(node) do |child|
      found ||= (child.type == :FCALL && child.children.first == name) ||
                (child.type == :VCALL && child.children.first == name)
    end
    found
  end

  def scan_delegates
    names = []
    each_node(@ast) do |node|
      names << node.children.first if %i[FCALL VCALL].include?(node.type)
    end
    names.uniq.each do |name|
      next if name == @action.split('#').last.to_sym

      begin
        delegated = @controller.instance_method(name)
        file, = delegated.source_location
        next unless file == @file

        scan(RubyVM::AbstractSyntaxTree.of(delegated))
      rescue NameError
        next
      end
      break if @renders.any?
    end
  end

  def scan_parameter_helpers
    seen = [@action.split('#').last.to_sym]
    queue = [@ast]
    2.times do
      next_queue = []
      queue.each do |root|
        names = []
        each_node(root) { |node| names << node.children.first if %i[FCALL VCALL].include?(node.type) }
        names.uniq.each do |name|
          next if seen.include?(name)

          seen << name
          begin
            helper = @controller.instance_method(name)
            file, = helper.source_location
            next unless file == @file

            helper_ast = RubyVM::AbstractSyntaxTree.of(helper)
            saved_renders = @renders
            saved_assignments = @assignments
            @renders = []
            scan(helper_ast)
            @renders = saved_renders
            @assignments = saved_assignments
            next_queue << helper_ast
          rescue NameError
            next
          end
        end
      end
      queue = next_queue
    end
  end

  def source_comments
    cursor = @ast.first_lineno - 2
    comments = []
    while cursor >= 0 && comments.length < 16
      line = @lines[cursor].strip
      break unless line.empty? || line.start_with?('#')

      comments.unshift(line.sub(/\A#\s?/, '')) if line.start_with?('#')
      cursor -= 1
    end
    comments.reject! { |line| line.match?(/\A(?:GET|POST|PUT|PATCH|DELETE)\b/) }
    comments.join(' ').gsub(/\s+/, ' ').strip[0, 650]
  end

  def build_operation(action_name)
    parts = @controller.name.sub(/Controller\z/, '').split('::')
    parts = parts.drop(2) if parts.first(2) == %w[Api V1]
    resource = parts.join(' ').underscore.tr('_/', ' ').squish
    verb = { 'index' => 'List', 'show' => 'Get', 'create' => 'Create', 'update' => 'Update', 'destroy' => 'Delete' }.fetch(action_name, action_name.humanize)
    summary = "#{verb} #{resource}".squish
    comments = source_comments
    description = comments.empty? ? summary : comments
    operation = {
      'summary' => summary,
      'tags' => [@path.split('/')[3].to_s.tr('_-', ' ').titleize],
      'description' => description,
      'x-rails-action' => @action,
      'x-controller-source' => "#{Pathname.new(@file).relative_path_from(Rails.root)}:#{@ast.first_lineno}",
      'x-contract-source' => 'controller'
    }
    operation['security'] = [] if public_action? || !@controller.ancestors.include?(ApplicationController)
    request_contract(operation)
    if @path.start_with?('/api/v1/icd/') && @verb == 'post'
      operation['requestBody'] = {
        'required' => false,
        'description' => 'Request body is forwarded unchanged to the ICD-11 upstream service.',
        'content' => { '*/*' => { 'schema' => { 'type' => 'string', 'format' => 'binary' } } }
      }
    end
    response_contract(operation)
    if comments.empty?
      inputs = @fields.keys.reject { |name| @path.include?("{#{name}}") }
      input_note = inputs.empty? ? 'No additional named request fields are read by this action.' : "Reads #{inputs.join(', ')}."
      success = operation['responses'].find { |status, _| status.start_with?('2') || status == 'default' }
      output_note = success ? success.last['description'] : ''
      operation['description'] = "#{summary}. #{input_note} #{output_note}".squish
    end
    operation
  end

  def public_action?
    return false unless @file && @ast

    source = @lines.take(@ast.first_lineno).join
    source.scan(/skip_before_action\s+:authenticate(?:\s*,\s*only:\s*(%i\[[^\]]+\]|:[a-z_]+))?/m).any? do |(only)|
      only.nil? || only.scan(/[a-z_]+/).include?(@action.split('#').last)
    end
  end

  def unavailable_operation(reason = nil)
    {
      'summary' => "Unavailable: #{@verb.upcase} #{@path}",
      'tags' => [@path.split('/')[3].to_s.tr('_-', ' ').titleize],
      'description' => reason || 'The registered controller action is absent or not dispatchable in this build.',
      'deprecated' => true,
      'parameters' => path_parameters,
      'responses' => { 'default' => { 'description' => 'The route cannot be dispatched to an implemented controller action.' } },
      'x-rails-action' => @action,
      'x-route-unavailable' => true
    }
  end

  def redirect_operation
    target, parameter = REDIRECTS.fetch(@path)
    location = parameter ? "#{target}?#{parameter}=<#{parameter}>" : target
    {
      'summary' => "Redirect to #{target}",
      'tags' => [@path.split('/')[3].to_s.tr('_-', ' ').titleize],
      'description' => "Legacy route. Redirects to #{location}; page and page_size query parameters are preserved where supported.",
      'parameters' => path_parameters + (parameter && @path != '/api/v1/locations/{location_id}/label' ? %w[page page_size].map do |name|
        { 'name' => name, 'in' => 'query', 'required' => false, 'schema' => { 'type' => 'integer' } }
      end : []),
      'responses' => { '301' => { 'description' => 'Permanent redirect to the current endpoint.', 'headers' => {
        'Location' => { 'description' => 'Redirect target.', 'schema' => { 'type' => 'string' } }
      } } },
      'deprecated' => true,
      'x-contract-source' => 'rails-redirect'
    }
  end
end
