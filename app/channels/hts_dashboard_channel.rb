# frozen_string_literal: true

# Live updates for the HTS dashboard summary. Replaces the frontend's 5s
# polling loop: clients subscribe here and re-fetch /hts_stats only when the
# server signals that HTS data changed (see HtsDashboardBroadcaster).
#
# The dashboard figures are global (scoped by program, not location) so a single
# shared stream serves every subscriber.
class HtsDashboardChannel < ApplicationCable::Channel
  STREAM = 'hts_dashboard_channel'

  # Signal subscribed dashboards that HTS data changed so they re-fetch. Callers
  # decide what counts as an HTS change; this only relays the notification.
  def self.broadcast_changed
    ActionCable.server.broadcast(STREAM, event: 'hts_dashboard_changed')
  rescue StandardError => e
    Rails.logger.warn("HTS dashboard broadcast failed: #{e.message}")
  end

  def subscribed
    stream_from STREAM
  end

  def unsubscribed; end
end
