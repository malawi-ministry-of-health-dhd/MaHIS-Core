#!/usr/bin/env ruby
# frozen_string_literal: true

# Add every registered API route to the Swagger files without rewriting the
# hand-authored operations produced by rswag specs. Run after swaggerize too.
require_relative '../config/environment'
require 'yaml'

class SwaggerRouteSync
  METHODS = %w[get post put patch delete head options].freeze
  CORE_FILE = Rails.root.join('swagger/v1/swagger.yaml')
  LAB_FILE = Rails.root.join('swagger/lab/v1/swagger.yaml')

  def initialize(check: false)
    @check = check
  end

  def run
    routes = route_inventory
    lab_routes = routes.select { |route| route[:path].start_with?('/api/v1/lab/') }
    lab_source = YAML.load_file(LAB_FILE)

    # The Core selector is the full backend inventory. Keep the curated Lab
    # examples in that view, while retaining the focused Lab selector as well.
    core_examples = operations_from(lab_source)
    sync_file(CORE_FILE, routes, core_examples)
    sync_file(LAB_FILE, lab_routes, {})
    puts "Rails API inventory: #{routes.length} operations (#{lab_routes.length} Lab)"
  end

  private

  def route_inventory
    engines = [Rails.application.routes, Lab::Engine.routes]
    engines.flat_map do |route_set|
      route_set.routes.flat_map do |route|
        raw_path = route.path.spec.to_s
        next [] unless raw_path.start_with?('/api/v1/')

        path = raw_path.sub(/\(\.:format\)\z/, '')
                       .gsub(/:([A-Za-z_]+)/, '{\1}')
                       .gsub(/\*([A-Za-z_]+)/, '{\1}')
        route.verb.to_s.split('|').filter_map do |verb|
          method = verb.downcase
          next unless METHODS.include?(method)

          { method: method, path: path,
            action: [route.defaults[:controller], route.defaults[:action]].compact.join('#') }
        end
      end
    end.uniq { |route| [route[:method], signature(route[:path])] }
  end

  def operations_from(document)
    document.fetch('paths').transform_values do |methods|
      methods.select { |key, _| METHODS.include?(key) }
    end
  end

  def signature(path)
    path.sub(%r{/\z}, '').gsub(/\{[^}]+\}/, '{}')
  end

  def matching_path(paths, path)
    paths.keys.find { |candidate| signature(candidate) == signature(path) }
  end

  def sync_file(file, routes, extra_operations)
    source = File.read(file)
    document = YAML.safe_load(source, aliases: true)
    paths = document.fetch('paths')
    additions = Hash.new { |hash, key| hash[key] = {} }

    extra_operations.each do |path, methods|
      methods.each do |method, operation|
        target = matching_path(paths, path) || matching_path(additions, path) || path
        additions[target][method] = operation unless covered?(paths, additions, path, method)
      end
    end

    routes.each do |route|
      target = matching_path(paths, route[:path]) || matching_path(additions, route[:path]) || route[:path]
      method = route[:method]
      next if covered?(paths, additions, route[:path], method)

      additions[target][method] = inventory_operation(route, target)
    end

    count = additions.values.sum(&:size)
    if @check
      puts "#{file.relative_path_from(Rails.root)}: #{count} undocumented route operations"
      additions.each { |path, methods| methods.each_key { |method| puts "  #{method.upcase} #{path}" } }
      raise 'Swagger route inventory is incomplete' if count.positive?
      return
    end

    if count.zero?
      puts "#{file.relative_path_from(Rails.root)}: already up to date"
      return
    end

    updated = insert_operations(source, paths, additions)
    parsed = YAML.safe_load(updated, aliases: true)
    raise 'Swagger paths were lost during sync' if parsed.fetch('paths').size < paths.size

    File.write(file, updated)
    puts "#{file.relative_path_from(Rails.root)}: added #{count} operations"
  end

  def inventory_operation(route, target)
    segments = target.split('/')
    tag = segments[3].to_s.tr('_-', '  ').split.map(&:capitalize).join(' ')
    parameters = target.scan(/\{([^}]+)\}/).flatten.map do |name|
      { 'name' => name, 'in' => 'path', 'required' => true,
        'schema' => { 'type' => 'string' } }
    end
    {
      'summary' => "#{route[:method].upcase} #{target}",
      'tags' => [tag],
      'description' => 'Route inventory entry. Request body and response schema have not yet been documented.',
      'parameters' => parameters,
      'responses' => {
        'default' => { 'description' => 'Response status and schema depend on the controller action.' }
      },
      'x-rails-action' => route[:action],
      'x-route-inventory' => true
    }
  end

  def covered?(paths, additions, path, method)
    [paths, additions].any? do |source|
      source.any? { |candidate, operations| signature(candidate) == signature(path) && operations.key?(method) }
    end
  end

  def insert_operations(source, existing_paths, additions)
    lines = source.lines
    path_lines = lines.each_index.filter_map do |index|
      match = lines[index].match(/^  (["']?)(\/?api\/v1\/[^"'\n]+)\1:\s*$/)
      [index, match[2]] if match
    end
    paths_end = lines.index { |line| line.match?(/\A(?:components|security|servers):/) }
    raise 'Cannot locate end of Swagger paths' unless paths_end

    positions = path_lines.to_h { |index, path| [path, index] }
    inserts = Hash.new { |hash, key| hash[key] = [] }
    additions.each do |path, methods|
      next if methods.empty?

      if existing_paths.key?(path)
        start = positions.fetch(path)
        following = path_lines.map(&:first).find { |index| index > start } || paths_end
        inserts[following] << yaml_fragment(methods, indent: 4)
      else
        inserts[paths_end] << yaml_fragment({ path => methods }, indent: 2)
      end
    end
    lines.each_with_index.map { |line, index| inserts[index].join + line }.join
  end

  def yaml_fragment(value, indent:)
    YAML.dump(value).sub(/\A---\s*\n/, '').lines.map do |line|
      line.strip.empty? ? "\n" : (' ' * indent) + line
    end.join
  end
end

SwaggerRouteSync.new(check: ARGV.include?('--check')).run
