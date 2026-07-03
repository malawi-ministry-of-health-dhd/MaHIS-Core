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

    # Count distinct patients actively enrolled in a program: those with a
    # date_enrolled but no date_completed on a non-voided patient_program row
    # for the program. Date scoping (when present) is applied to date_enrolled.
    # Relies on the host query class to define #apply_date_scope and set
    # @start_date/@end_date, matching the ANC/PNC/Labour query classes.
    def count_active_patient_program(program_id)
      return 0 if program_id.blank?

      scope = PatientProgram.unscoped.where(program_id: program_id, voided: 0, date_completed: nil)
      scope = scope.where(location_filter) if resolved_location_id.present?
      scope = apply_date_scope(scope, 'date_enrolled') if @start_date.present? || @end_date.present?
      scope.distinct.count(:patient_id)
    end
  end
end
