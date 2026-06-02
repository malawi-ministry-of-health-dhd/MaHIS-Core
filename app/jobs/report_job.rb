# frozen_string_literal: true

class ReportJob < ApplicationJob
  queue_as :default

  def perform(clazzname, kwargs)
    lock_key = "report_job:running:#{clazzname}:#{kwargs[:location_id]}:#{kwargs[:name]}"
    lock_ttl = 90 * 60  # 90 minutes in seconds

    acquired = Sidekiq.redis { |r| r.set(lock_key, 1, nx: true, ex: lock_ttl) }
    unless acquired
      logger.info("ReportJob: skipping #{clazzname}(#{kwargs[:name]}) — already running")
      return
    end

    begin
      logger.debug("Running report job #{clazzname}(#{kwargs})")

      User.current = User.find(kwargs.delete(:user))
      Location.current = Location.find(kwargs.delete(:location_id))

      clazz = clazzname.constantize
      report_engine = clazz.new
      report_engine.generate_report(**kwargs)
    ensure
      Sidekiq.redis { |r| r.del(lock_key) }
    end
  end
end
