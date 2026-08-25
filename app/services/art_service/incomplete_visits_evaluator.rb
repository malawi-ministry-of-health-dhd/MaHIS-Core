# frozen_string_literal: true

module ArtService
  class OptimizedWorkflowEngine < WorkflowEngine
    def self.activities(property_value)
      encounters = (property_value&.split(',') || []).filter_map do |activity|
        case activity
        when /ART adherence/i then ART_ADHERENCE
        when /HIV clinic consultations/i then HIV_CLINIC_CONSULTATION
        when /HIV first visits/i then HIV_CLINIC_REGISTRATION
        when /HIV reception visits/i then HIV_RECEPTION
        when /HIV staging visits/i then HIV_STAGING
        when /Appointments/i then APPOINTMENT
        when /Drug Dispensations/ then DISPENSING
        when /Prescriptions/i then TREATMENT
        when /Vitals/i then VITALS
        when /Symptom screening/i then SYMPTOM_SCREENING
        when /AHD screening/i then AHD_SCREENING
        end
      end

      Set.new(encounters + [FAST_TRACK])
    end

    def initialize(patient:, date:, program:, encounter_types: nil, encounters: nil, activities: nil)
      super(patient:, date:, program:)
      @activities = activities if activities
      @encounter_types = encounter_types || EncounterType.where(name: workflow_states).index_by { |type| type.name.upcase }
      @todays_encounters = encounters || Encounter.unscoped
                                             .where(patient_id: patient.patient_id,
                                                    program_id: program.program_id,
                                                    encounter_datetime: day_bounds.first..day_bounds.last)
                                             .includes(:orders)
                                             .to_a
      @condition_results = {}
    end

    def next_encounter
      state = INITIAL_STATE
      loop do
        state = next_state(state)
        break if state == END_STATE

        encounter_type = encounter_type(state)
        if encounter_type.blank? && state == HIV_CLINIC_CONSULTATION_CLINICIAN
          next if seen_by_clinician?

          encounter_type = encounter_type(HIV_CLINIC_CONSULTATION)
          next if encounter_type.blank?

          encounter_type.name = HIV_CLINIC_CONSULTATION_CLINICIAN
          return encounter_type if referred_to_clinician?

          next
        end

        next if encounter_type.blank?

        return htn_transform(encounter_type) if valid_state?(state)
      end

      nil
    end

    private

    def load_user_activities
      self.class.activities(user_property('Activities')&.property_value)
    end

    def workflow_states
      ENCOUNTER_SM.values.grep(String)
    end

    def day_bounds
      TimeUtils.day_bounds(@date)
    end

    def encounter_type(state)
      @encounter_types[state]
    end

    def encounter_exists?(type)
      return false if type.name == VITALS

      encounters = @todays_encounters.select { |encounter| encounter.encounter_type == type.encounter_type_id }
      return encounters.any? unless type.name == TREATMENT

      encounters.any? do |encounter|
        encounter.orders.any? { |order| !order.voided? && order.quantity.to_f.positive? }
      end
    end

    def valid_state?(state)
      return false if encounter_exists?(encounter_type(state)) || !art_activity_enabled?(state)

      (STATE_CONDITIONS[state] || []).all? do |condition|
        @condition_results.fetch(condition) { @condition_results[condition] = send(condition) }
      end
    end
  end

  class IncompleteVisitsEvaluator
    def initialize(program:, patient_visit_dates:)
      @program = program
      @patient_visit_dates = patient_visit_dates
    end

    def call
      return {} if @patient_visit_dates.blank?

      visits_by_patient = @patient_visit_dates.group_by(&:first)
      patients_by_id = Patient.where(patient_id: visits_by_patient.keys).index_by(&:patient_id)
      encounter_types = EncounterType.where(name: workflow_states).index_by { |type| type.name.upcase }
      encounters_by_patient_date = load_encounters(visits_by_patient.keys)
      activities_property = UserProperty.find_by(user_id: User.current.user_id, property: 'Activities')
      activities = OptimizedWorkflowEngine.activities(activities_property&.property_value)
      incomplete_dates = Hash.new { |dates, patient_id| dates[patient_id] = [] }

      ActiveRecord::Base.connection.cache do
        visits_by_patient.each do |patient_id, visits|
          patient = patients_by_id[patient_id]
          next if patient.blank?

          visits.each do |_patient_id, visit_date|
            date = visit_date.to_date
            engine = OptimizedWorkflowEngine.new(
              patient:,
              date:,
              program: @program,
              encounter_types:,
              encounters: encounters_by_patient_date[[patient_id, date]] || [],
              activities:
            )
            next if engine.next_encounter.blank?

            incomplete_dates[patient_id] << date
          end
        end
      end

      incomplete_dates
    end

    private

    def workflow_states
      WorkflowEngine::ENCOUNTER_SM.values.grep(String)
    end

    def load_encounters(patient_ids)
      start_date = @patient_visit_dates.map { |_patient_id, date| date.to_date }.min
      end_date = @patient_visit_dates.map { |_patient_id, date| date.to_date }.max
      start_time = TimeUtils.day_bounds(start_date).first
      end_time = TimeUtils.day_bounds(end_date).last

      Encounter.unscoped
               .where(patient_id: patient_ids,
                      program_id: @program.program_id,
                      encounter_datetime: start_time..end_time)
               .includes(:orders)
               .to_a
               .group_by { |encounter| [encounter.patient_id, encounter.encounter_datetime.to_date] }
    end
  end
end