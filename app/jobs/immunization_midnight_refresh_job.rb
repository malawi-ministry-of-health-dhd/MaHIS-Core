class ImmunizationMidnightRefreshJob < ApplicationJob
  queue_as :default

  def perform(*args)
    # Do something later
    today = Date.today
    start_date = today.beginning_of_year.to_s
    end_date = today.to_s

    ImmunizationCacheDatum.pluck(:location_id).each do |location_id|
      ImmunizationReportJob.perform_later(start_date, end_date, location_id)
    end
  end
end
