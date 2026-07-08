# frozen_string_literal: true

# Notifies subscribed HTS dashboards (see HtsDashboardChannel) that HTS data
# changed so they refresh. We broadcast a lightweight signal rather than the
# stats themselves because the dashboard figures are relative to each client's
# own session date / order type; clients re-fetch /hts_stats with their params.
#
# Scoped to HTS writes via the program_id the request already carries (the same
# value used to load the lab-tests engine), so ART/TB lab activity does not wake
# HTS dashboards.
module HtsDashboardBroadcaster
  private

  def broadcast_hts_dashboard_changed
    return unless params[:program_id].to_i == HtsService::Dashboard::HTS_PROGRAM_ID

    HtsDashboardChannel.broadcast_changed
  end
end
