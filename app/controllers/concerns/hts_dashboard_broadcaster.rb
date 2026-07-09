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
    return unless hts_dashboard_program_id?(params[:program_id])

    HtsDashboardChannel.broadcast_changed
  end

  def hts_dashboard_program_id?(program_id)
    program_id = program_id.to_i
    program_id.positive? && hts_dashboard_program_ids.include?(program_id)
  end

  def hts_dashboard_program_ids
    @hts_dashboard_program_ids ||= begin
      ids = [HtsService::Dashboard::HTS_PROGRAM_ID]
      ids.concat(
        Program.unscoped
               .where('UPPER(name) IN (?)', ['HTS PROGRAM', 'HTC PROGRAM'])
               .pluck(:program_id)
      )
      ids.compact.map(&:to_i).uniq
    rescue StandardError => e
      Rails.logger.warn("HTS dashboard program lookup failed: #{e.message}")
      [HtsService::Dashboard::HTS_PROGRAM_ID]
    end
  end
end
