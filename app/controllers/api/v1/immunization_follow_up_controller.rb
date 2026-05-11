class Api::V1::ImmunizationFollowUpController < ApplicationController
  def missed_immunizations
    location_id = User.current.location_id

    missed_visits = ImmunizationService::FollowUp.new.fetch_missed_immunizations(location_id)
    cache = ImmunizationCacheDatum.find_or_initialize_by(name: 'missed_immunizations', location_id:)
    cache.value = missed_visits
    cache.save!

    render json: [cache], status: :ok
  rescue StandardError => e
    Rails.logger.error("Failed to refresh missed immunizations for location #{location_id}: #{e.class}: #{e.message}")

    stale_cache = ImmunizationCacheDatum.where(name: 'missed_immunizations', location_id:)
    return render json: stale_cache, status: :ok if stale_cache.exists?

    render json: {}, status: :not_found
  end
end
