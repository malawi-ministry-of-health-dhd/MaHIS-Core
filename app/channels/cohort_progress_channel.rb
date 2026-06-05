# frozen_string_literal: true

class CohortProgressChannel < ApplicationCable::Channel
  TOTAL_TABLES = 11

  def subscribed
    location_id = params[:location_id]
    name        = params[:name]
    stream_from "cohort_progress:#{location_id}:#{name}"
  end

  def unsubscribed
    # no cleanup needed
  end

  # Convenience class method called by CohortBuilder after each table is loaded.
  # +location_id+ and +name+ are used to target the correct stream.
  def self.broadcast_progress(location_id:, name:, completed:, step: nil)
    ActionCable.server.broadcast(
      "cohort_progress:#{location_id}:#{name}",
      { completed: completed, total: TOTAL_TABLES, step: step }
    )
  end
end
