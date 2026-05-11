# frozen_string_literal: true

module MnhService
  module LocationScope
    private

    def resolved_location_id
      @resolved_location_id ||= @location_id.presence || Location.current&.location_id || User.current&.location_id
    end

    def location_filter
      return {} if resolved_location_id.blank?

      { location_id: resolved_location_id.to_s }
    end

    def scoped_observations_for(program_id)
      scope = Observation.unscoped.joins(:encounter).where(
        encounter: { program_id: program_id, voided: 0 },
        obs: { voided: 0 }
      )
      return scope if resolved_location_id.blank?

      scope.where(encounter: location_filter, obs: location_filter)
    end

    def scoped_encounters_for(program_id)
      scope = Encounter.unscoped.where(program_id: program_id, voided: 0)
      return scope if resolved_location_id.blank?

      scope.where(location_filter)
    end
  end
end
