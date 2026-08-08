# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # unique :until_executed, on_conflict: :log # Commented out - activejob-uniqueness not compatible with Rails 8.1

  around_perform :restore_current_context

  def login(user_id, location_id)
    # Sidekiq threads are reused. Never allow Location.current from the
    # previous job to scope the actor lookup for the next job.
    User.current = User.unscoped.where(retired: 0).find(user_id)
    Location.current = Location.unscoped.where(retired: 0).find(location_id)
  end

  private

  def restore_current_context
    previous_user = User.current
    previous_location = Location.current
    yield
  ensure
    User.current = previous_user
    Location.current = previous_location
  end
end
