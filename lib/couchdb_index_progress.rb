# frozen_string_literal: true

require 'rest-client'
require 'json'

# Reads live index-build progress from CouchDB's /_active_tasks endpoint.
# While a Mango/view index is building, CouchDB reports an entry of
# type "indexer" with the database, design document, and a 0-100 progress
# value (plus changes_done/total_changes). This is the authoritative source
# of index build progress — nothing is stored locally.
module CouchdbIndexProgress
  module_function

  Task = Struct.new(:database, :design_document, :progress, :changes_done, :total_changes, keyword_init: true) do
    def label
      ddoc = design_document.to_s.sub(%r{\A_design/}, '')
      db = database.to_s.split('/').last.to_s.sub(/\.\d+\z/, '') # strip shard suffix
      ddoc.empty? ? db : "#{db}/#{ddoc}"
    end
  end

  # Returns an array of Task structs for in-flight indexer tasks, or [] if
  # CouchDB is unreachable or idle.
  def active
    raw = fetch_active_tasks
    raw.select { |t| t['type'] == 'indexer' }.map do |t|
      Task.new(
        database: t['database'],
        design_document: t['design_document'],
        progress: t['progress'].to_i,
        changes_done: t['changes_done'].to_i,
        total_changes: t['total_changes'].to_i
      )
    end
  end

  # True when CouchDB reports no indexer tasks running.
  def idle?
    active.empty?
  end

  def fetch_active_tasks
    return [] unless couchdb_configured?

    response = RestClient::Request.execute(
      method: :get,
      url: couchdb_url('_active_tasks'),
      headers: { accept: :json },
      timeout: 5,
      open_timeout: 5
    )
    JSON.parse(response.body)
  rescue StandardError
    []
  end

  # CouchdbSync#couchdb_url/#couchdb_configured? are instance methods; expose
  # them at module-function level by delegating through a tiny helper object.
  def couchdb_url(*segments)
    helper.couchdb_url(*segments)
  end

  def couchdb_configured?
    helper.couchdb_configured?
  end

  def helper
    @helper ||= Object.new.extend(CouchdbSync)
  end
end
