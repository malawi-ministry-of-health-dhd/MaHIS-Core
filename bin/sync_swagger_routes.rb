#!/usr/bin/env ruby
# frozen_string_literal: true

# Add every registered API route to the Swagger files without rewriting the
# hand-authored operations produced by rswag specs. Source-backed operations
# describe request fields and response branches; missing actions are flagged.
require_relative '../config/environment'
require_relative '../lib/swagger_controller_contract'
require_relative '../lib/swagger_open_api_normalizer'
require 'yaml'

class SwaggerRouteSync
  METHODS = %w[get post put patch delete head options].freeze
  CORE_FILE = Rails.root.join('swagger/v1/swagger.yaml')
  LAB_FILE = Rails.root.join('swagger/lab/v1/swagger.yaml')
  AUTH_FILE = Rails.root.join('swagger/auth_operations.yaml')
  UNAVAILABLE_REPORT = Rails.root.join('docs/API_UNAVAILABLE.md')

  def initialize(check: false)
    @check = check
  end

  def run
    routes = route_inventory
    lab_routes = routes.select { |route| route[:path].start_with?('/api/v1/lab/') }
    lab_source = YAML.load_file(LAB_FILE)
    @auth_operations = YAML.load_file(AUTH_FILE).fetch('paths')

    # The Core selector is the full backend inventory. Keep the curated Lab
    # examples in that view, while retaining the focused Lab selector as well.
    core_examples = operations_from(lab_source)
    sync_file(CORE_FILE, routes, core_examples)
    sync_file(LAB_FILE, lab_routes, {})
    sync_unavailable_report
    puts "Rails API inventory: #{routes.length} operations (#{lab_routes.length} Lab)"
    [CORE_FILE, LAB_FILE].each do |file|
      document = YAML.safe_load_file(file, aliases: true)
      counts = Hash.new(0)
      document.fetch('paths').each_value do |methods|
        methods.each_value do |operation|
          next unless operation.is_a?(Hash) && operation['responses']

          kind = if operation['x-route-inventory']
                   'route-only'
                 elsif operation['x-route-unavailable']
                   'unavailable'
                 else
                   operation['x-contract-source'] || 'curated'
                 end
          counts[kind] += 1
        end
      end
      puts "#{file.relative_path_from(Rails.root)}: #{counts.sort.map { |kind, count| "#{count} #{kind}" }.join(', ')}"
    end
  end

  private

  def sync_unavailable_report
    document = YAML.safe_load_file(CORE_FILE, aliases: true)
    rows = document.fetch('paths').flat_map do |path, methods|
      methods.filter_map do |method, operation|
        next unless operation.is_a?(Hash) && operation['x-route-unavailable']

        [method.upcase, path, operation['x-rails-action'].presence || 'none', operation.fetch('description')]
      end
    end.sort_by { |method, path, _, _| [path, method] }
    lines = [
      '# Registered API routes without a working action',
      '',
      "#{rows.length} route methods are registered but unavailable in this build. Swagger marks them deprecated.",
      'The controller target is missing, not exposed as an action, or explicitly returns “Not implemented.”',
      '',
      '| Method | Path | Controller target | Reason |',
      '| --- | --- | --- | --- |'
    ]
    rows.each do |method, path, action, reason|
      lines << "| `#{method}` | `#{path}` | `#{action}` | #{reason.gsub('|', '\\|')} |"
    end
    report = lines.join("\n") + "\n"
    if @check
      raise "#{UNAVAILABLE_REPORT.relative_path_from(Rails.root)} needs sync" unless UNAVAILABLE_REPORT.exist? && UNAVAILABLE_REPORT.read == report
    elsif !UNAVAILABLE_REPORT.exist? || UNAVAILABLE_REPORT.read != report
      UNAVAILABLE_REPORT.write(report)
      puts "#{UNAVAILABLE_REPORT.relative_path_from(Rails.root)}: updated #{rows.length} unavailable routes"
    end
  end

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
    original_source = File.read(file)
    source = original_source
    document = YAML.safe_load(source, aliases: true)
    overrides = if file == LAB_FILE
                  @auth_operations.select { |path, _| path.start_with?('/api/v1/lab/') }
                else
                  @auth_operations
                end

    overrides.each do |path, methods|
      methods.each do |method, operation|
        current = document.fetch('paths').dig(path, method)
        next if current.nil? || current == operation

        if @check
          raise "#{file.relative_path_from(Rails.root)}: #{method.upcase} #{path} needs auth documentation sync"
        end

        source = replace_operation(source, path, method, operation)
        document = YAML.safe_load(source, aliases: true)
      end
    end

    # Refresh source-backed contracts when their controller changes. Curated
    # rswag/auth operations are left untouched.
    document.fetch('paths').each do |path, methods|
      methods.each do |method, operation|
        next unless METHODS.include?(method) && operation.is_a?(Hash)
        next unless operation['x-route-inventory'] || operation['x-contract-source'] || operation['x-route-unavailable']

        route = routes.find { |entry| entry[:method] == method && signature(entry[:path]) == signature(path) }
        next unless route

        generated = SwaggerOpenApiNormalizer.new.normalize_operation(
          SwaggerControllerContract.new(route.merge(path: path)).operation
        )
        next if generated == operation

        if @check
          raise "#{file.relative_path_from(Rails.root)}: #{method.upcase} #{path} needs controller documentation sync\n" \
                "Checked-in operation:\n#{YAML.dump(operation)}Generated operation:\n#{YAML.dump(generated)}"
        end

        source = replace_operation(source, path, method, generated)
      end
    end
    document = YAML.safe_load(source, aliases: true)

    # rswag examples occasionally emit Rails-style shorthand that is not valid
    # OpenAPI 3. Normalize those operations without replacing their examples.
    normalizer = SwaggerOpenApiNormalizer.new
    document.fetch('paths').each do |path, methods|
      methods.each do |method, operation|
        next unless METHODS.include?(method) && operation.is_a?(Hash)

        normalized = normalizer.normalize_operation(operation)
        next if normalized == operation

        if @check
          raise "#{file.relative_path_from(Rails.root)}: #{method.upcase} #{path} needs OpenAPI normalization"
        end

        source = replace_operation(source, path, method, normalized)
      end
    end
    document = YAML.safe_load(source, aliases: true)

    paths = document.fetch('paths')
    additions = Hash.new { |hash, key| hash[key] = {} }

    extra_operations.each do |path, methods|
      methods.each do |method, operation|
        target = matching_path(paths, path) || matching_path(additions, path) || path
        additions[target][method] = operation unless covered?(paths, additions, path, method)
      end
    end

    overrides.each do |path, methods|
      methods.each do |method, operation|
        next if paths.dig(path, method) == operation

        additions[path][method] = operation unless paths.fetch(path, {}).key?(method)
      end
    end

    routes.each do |route|
      target = matching_path(paths, route[:path]) || matching_path(additions, route[:path]) || route[:path]
      method = route[:method]
      next if covered?(paths, additions, route[:path], method)

      additions[target][method] = SwaggerOpenApiNormalizer.new.normalize_operation(
        SwaggerControllerContract.new(route.merge(path: target)).operation
      )
    end

    count = additions.values.sum(&:size)
    if @check
      puts "#{file.relative_path_from(Rails.root)}: #{count} missing route operations"
      additions.each { |path, methods| methods.each_key { |method| puts "  #{method.upcase} #{path}" } }
      raise 'Swagger route inventory is incomplete' if count.positive?
      return
    end

    if count.zero?
      if source != original_source
        File.write(file, source)
        puts "#{file.relative_path_from(Rails.root)}: updated operation documentation"
      else
        puts "#{file.relative_path_from(Rails.root)}: already up to date"
      end
      return
    end

    updated = insert_operations(source, paths, additions)
    parsed = YAML.safe_load(updated, aliases: true)
    raise 'Swagger paths were lost during sync' if parsed.fetch('paths').size < paths.size

    File.write(file, updated)
    puts "#{file.relative_path_from(Rails.root)}: added #{count} operations"
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

  def replace_operation(source, path, method, operation)
    lines = source.lines
    path_line = lines.index { |line| line.match?(/^  ["']?#{Regexp.escape(path)}["']?:\s*$/) }
    raise "Cannot find Swagger path #{path}" unless path_line

    start = ((path_line + 1)...lines.length).find { |index| lines[index].match?(/^    #{method}:\s*$/) }
    raise "Cannot find #{method.upcase} #{path}" unless start

    finish = ((start + 1)...lines.length).find do |index|
      lines[index].match?(/^    (?:#{METHODS.join('|')}):\s*$/) ||
        lines[index].match?(/^  \S/) || lines[index].match?(/^\S/)
    end || lines.length

    (lines[0...start] + [yaml_fragment({ method => operation }, indent: 4)] + lines[finish..]).join
  end

  def yaml_fragment(value, indent:)
    YAML.dump(value).sub(/\A---\s*\n/, '').lines.map do |line|
      line.strip.empty? ? "\n" : (' ' * indent) + line
    end.join
  end
end

SwaggerRouteSync.new(check: ARGV.include?('--check')).run
