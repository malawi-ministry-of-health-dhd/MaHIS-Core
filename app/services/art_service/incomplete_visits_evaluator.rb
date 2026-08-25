# frozen_string_literal: true

module ArtService
  class OptimizedHtnWorkflow < HtnWorkflow
    private

    def global_property(name, location_id = nil)
      @global_properties ||= {}
      key = [name, location_id || User.current.location_id]
      @global_properties.fetch(key) do
        @global_properties[key] = super
      end
    end
  end

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

    def initialize(patient:, date:, program:, encounter_types: nil, encounters: nil, activities: nil,
                   observations: nil, patient_states: nil, arv_ids: nil, registered_patient_ids: nil,
                   staged_patient_ids: nil, clinician_ids: nil, concepts: nil,
                   fast_track_enabled: nil, htn_enabled: nil, htn_workflow: nil)
      @patient = patient
      @program = program
      @date = date
      @activities = activities || load_user_activities
      @fast_track_enabled = fast_track_enabled == true
      @htn_enabled = htn_enabled
      @htn_workflow = htn_workflow
      @encounter_types = encounter_types || EncounterType.where(name: workflow_states).index_by { |type| type.name.upcase }
      @todays_encounters = encounters || Encounter.unscoped
                                             .where(patient_id: patient.patient_id,
                                                    program_id: program.program_id,
                                                    encounter_datetime: day_bounds.first..day_bounds.last)
                                               .includes(orders: :drug_order)
                                             .to_a
                                      @observations = observations || []
                                      @patient_states = patient_states || []
                                      @arv_ids = arv_ids || []
                                      @registered_patient_ids = registered_patient_ids || []
                                      @staged_patient_ids = staged_patient_ids || []
                                      @clinician_ids = clinician_ids || []
                                      @concepts = concepts || {}
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

    def fast_track_activated?
      @fast_track_enabled
    end

    def htn_transform(encounter_type)
      return encounter_type unless @htn_enabled

      (@htn_workflow ||= OptimizedHtnWorkflow.new).next_htn_encounter(@patient, encounter_type, @date)
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

    def patient_not_on_fast_track?
      observation = observations_for('Fast').select { |item| item.obs_datetime <= day_bounds.last }
                                                  .max_by(&:obs_datetime)
      (observation&.value_coded || concept_id('No')).to_i == concept_id('No')
    end

    def patient_has_not_completed_fast_track_visit?
      !observations_for('Fast track visit').any? do |observation|
        observation.value_coded.to_i == concept_id('Yes') &&
          observation.obs_datetime.between?(*day_bounds)
      end
    end

    def patient_received_art?
      observations_for_value_drug.any? { |observation| observation.obs_datetime < @date.to_date }
    end

    def patient_should_get_treatment?
      return false if referred_to_clinician? && !seen_by_clinician?

      !observations_for('Prescribe drugs').any? do |observation|
        observation.value_coded.to_i == concept_id('No') && observation.obs_datetime.between?(*day_bounds)
      end
    end

    def patient_got_treatment?
      treatment_type_id = encounter_type(TREATMENT)&.encounter_type_id
      @todays_encounters.any? do |encounter|
        encounter.encounter_type == treatment_type_id &&
          encounter.orders.any? { |order| !order.voided? && order.quantity.to_f.positive? }
      end
    end

    def dispensing_complete?
      treatment_type_id = encounter_type(TREATMENT)&.encounter_type_id
      prescription = @todays_encounters
                     .select { |encounter| encounter.encounter_type == treatment_type_id }
                     .max_by(&:encounter_datetime)
      return false unless prescription

      drug_orders = prescription.orders.filter_map(&:drug_order)
      !drug_orders.empty? && drug_orders.all? { |drug_order| drug_order.amount_needed <= 0 }
    end

    def patient_does_not_have_height_and_weight?
      return true if patient_has_no_weight_today?
      return true if patient_has_no_height?

      patient_has_no_height_today? && patient_is_a_minor?
    end

    def patient_has_no_weight_today?
      !observations_for('Weight').any? { |observation| observation.obs_datetime.between?(*day_bounds) }
    end

    def patient_has_no_height?
      !observations_for('Height (cm)').any? { |observation| observation.obs_datetime < day_bounds.last }
    end

    def patient_has_no_height_today?
      !observations_for('Height (cm)').any? { |observation| observation.obs_datetime.between?(*day_bounds) }
    end

    def patient_is_alive?
      !@patient_states.any? do |state|
        state.patient_program.patient_id == @patient.patient_id &&
          state.state == 3 && state.start_date <= @date
      end
    end

    def patient_not_registered?
      !@registered_patient_ids.include?(@patient.patient_id)
    end

    def patient_checked_in?
      reception_type_id = encounter_type(HIV_RECEPTION)&.encounter_type_id
      reception_encounter_ids = @todays_encounters
                               .select { |encounter| encounter.encounter_type == reception_type_id }
                               .map(&:encounter_id)
      @observations.any? do |observation|
        reception_encounter_ids.include?(observation.encounter_id) &&
          observation.concept_id == concept_id('Patient present') &&
          observation.value_coded.to_i == concept_id('Yes')
      end
    end

    def patient_not_already_staged?
      !@staged_patient_ids.include?(@patient.patient_id)
    end

    def patient_not_visiting?
      observation = observations_for('Type of patient')
                    .max_by { |item| [item.obs_datetime, item.obs_id] }
      observation.blank? || observation.value_coded != concept_id('External consultation')
    end

    def patient_not_coming_for_drug_refill?
      observation = observations_for('Type of patient')
                    .max_by { |item| [item.obs_datetime, item.obs_id] }
      observation.blank? || observation.value_coded != concept_id('Drug refill')
    end

    def patient_has_symptoms_screening?
      symptom_ids = observations_for('AHD Symptom').filter_map(&:value_coded)
      yes_id = concept_id('Yes')
      symptom_encounter_ids = @todays_encounters
                             .select { |encounter| encounter.encounter_type == encounter_type(SYMPTOM_SCREENING)&.encounter_type_id }
                             .map(&:encounter_id)
      @observations.any? do |observation|
        symptom_ids.include?(observation.concept_id) && observation.value_coded.to_i == yes_id &&
          symptom_encounter_ids.include?(observation.encounter_id) &&
          observation.obs_datetime.between?(*day_bounds)
      end
    end

    def seen_by_clinician?
      observations_for('Medication orders').any? do |observation|
        @clinician_ids.include?(observation.creator) && observation.obs_datetime.between?(*day_bounds)
      end
    end

    def referred_to_clinician?
      observation = observations_for('Refer to ART clinician')
                          .select { |item| item.obs_datetime.between?(*day_bounds) }
                          .max_by { |item| [item.date_created, item.obs_datetime] }
      observation&.value_coded.to_i == concept_id('Yes')
    end

    def observations_for(concept_name)
      @observations.select { |observation| observation.concept_id == concept_id(concept_name) }
    end

    def concept_id(name)
      @concepts[name.downcase]&.concept_id
    end

    def observations_for_value_drug
      @observations.select { |observation| @arv_ids.include?(observation.value_drug) }
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
      arv_ids = Drug.arv_drugs.pluck(:drug_id)
      concept_names = [
        'AHD Symptom', 'Yes', 'No', 'Fast', 'Fast track visit',
        'Medication orders', 'Refer to ART clinician', 'Patient present',
        'Type of patient', 'External consultation', 'Drug refill',
        'Prescribe drugs', 'Weight', 'Height (cm)'
      ]
      concepts = ConceptName.where(name: concept_names).index_by { |concept| concept.name.downcase }
      concept_ids = concepts.values.compact.map(&:concept_id)
      observations_by_patient = load_observations(visits_by_patient.keys, concept_ids:, arv_ids:)
      patient_states_by_patient = load_patient_states(visits_by_patient.keys)
      registered_patient_ids = load_patient_ids_with_encounter(encounter_types.fetch('HIV CLINIC REGISTRATION', nil))
      staged_patient_ids = load_patient_ids_with_encounter(encounter_types.fetch('HIV STAGING', nil), before: @patient_visit_dates.map { |_id, date| date.to_date }.max + 1.day)
      clinician_ids = User.joins(:roles).where(role: { role: 'Clinician' }).pluck(:user_id)
      activities_property = UserProperty.find_by(user_id: User.current.user_id, property: 'Activities')
      activities = OptimizedWorkflowEngine.activities(activities_property&.property_value)
      fast_track_enabled = global_flag('enable.fast.track')
      htn_enabled = global_flag('activate.htn.enhancement')
      htn_workflow = OptimizedHtnWorkflow.new if htn_enabled
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
              activities:,
              observations: observations_by_patient[patient_id] || [],
              patient_states: patient_states_by_patient[patient_id] || [],
              arv_ids:,
              registered_patient_ids:,
              staged_patient_ids:,
              clinician_ids:,
              concepts:,
              fast_track_enabled:,
              htn_enabled:,
              htn_workflow:
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

    def load_observations(patient_ids, concept_ids:, arv_ids:)
      end_time = TimeUtils.day_bounds(@patient_visit_dates.map { |_id, date| date.to_date }.max).last

      Observation.joins(:encounter)
                 .where(person_id: patient_ids, encounter: { program_id: @program.program_id })
                 .where('obs_datetime <= ?', end_time)
                 .where('concept_id IN (?) OR value_drug IN (?)', concept_ids, arv_ids)
                 .to_a
                 .group_by(&:person_id)
    end

    def load_patient_states(patient_ids)
      PatientState.joins(:patient_program)
                  .where(patient_program: { patient_id: patient_ids, program_id: @program.program_id })
                  .where('patient_state.start_date <= ?', @patient_visit_dates.map { |_id, date| date.to_date }.max)
                  .includes(:patient_program)
                  .to_a
                  .group_by { |state| state.patient_program.patient_id }
    end

    def load_patient_ids_with_encounter(encounter_type, before: nil)
      return [] unless encounter_type

      scope = Encounter.unscoped.where(patient_id: @patient_visit_dates.map(&:first).uniq,
                                       program_id: @program.program_id,
                                       encounter_type: encounter_type.encounter_type_id)
      scope = scope.where('encounter_datetime < ?', before) if before
      scope.distinct.pluck(:patient_id)
    end

    def global_flag(property)
      value = GlobalProperty.unscoped.find_by(property:, location_id: User.current.location_id)&.property_value
      value.to_s.casecmp?('true') == true
    end
  end
end