# frozen_string_literal: true

class ReportingFactsRefreshJob < ApplicationJob
  queue_as :default

  def perform
    Reporting::PatientArtFactsRefresh.call
  end
end
