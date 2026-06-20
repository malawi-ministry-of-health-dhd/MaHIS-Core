# frozen_string_literal: true

require Rails.root.join('lib', 'tidb_reporting').to_s

class ReportJob < ApplicationJob
  queue_as :default

  def perform(clazzname, kwargs)
    location_id = kwargs[:location_id]
    name        = kwargs[:name]

    # Execution lock — prevents a stale duplicate job (e.g. Sidekiq retry) from
    # running concurrently with one that is already in progress.
    exec_lock_key = "report_job:running:#{clazzname}:#{location_id}:#{name}"
    lock_ttl      = 90 * 60

    acquired = Sidekiq.redis { |r| r.set(exec_lock_key, 1, nx: true, ex: lock_ttl) }
    unless acquired
      logger.info("ReportJob: skipping #{clazzname}(#{name}) — already running")
      return
    end

    # Reservation key set by queue_report — keep alive while job runs then release.
    reservation_key = "report_job:reserved:#{clazzname}:#{location_id}"

    begin
      logger.debug("Running report job #{clazzname}(#{kwargs})")

      User.current = User.find(kwargs.delete(:user))
      Location.current = Location.find(kwargs.delete(:location_id))

      clazz = clazzname.constantize
      report_engine = clazz.new
      TidbReporting.with_analytics_session do
        report_engine.generate_report(**kwargs)
      end
    ensure
      Sidekiq.redis do |r|
        r.del(exec_lock_key)
        r.del(reservation_key)
      end
    end
  end
end
