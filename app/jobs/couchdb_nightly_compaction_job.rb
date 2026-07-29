# frozen_string_literal: true

class CouchdbNightlyCompactionJob < ApplicationJob
  queue_as :default

  def perform
    CouchdbCompactionService.run!
  end
end
