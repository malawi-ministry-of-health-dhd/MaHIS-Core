# frozen_string_literal: true

class VisitService
  include CouchdbSync
  include EncounterCreation

  def create_update_visit(visit_params)
    sync_status = visit_params[:sync_status]

    if sync_status == 'update'
      close_visit(visit_params)
    elsif sync_status == 'create'
      create_visit(visit_params)
    end
  end

  def create_visit(visit_params)
    patient_id = visit_params[:patient_id]
    identifier = visit_params[:identifier]
    stage_params = visit_params[:stage]

    if identifier.present?
      patient_identifier = PatientIdentifier.where(identifier: identifier).first
      patient_id = patient_identifier[:patient_id] if patient_identifier.present?
    end

    # Create encounter first
    create_encounter(patient_id, 1,
      {
        program_id: visit_params[:program_id],
        location_id: visit_params[:location_id],
        encounter_datetime: visit_params[:date_started],
        provider_id: visit_params[:provider_id]
      })

    # Check if visit already exists
    checkVisit = Visit.where(patient_id: patient_id, date_stopped: nil).first
    if checkVisit.present?
      visit_data = checkVisit.attributes
      visit_data[:identifier] = identifier if identifier.present?
      visit_data[:full_name] = Patient.find_by(patient_id: patient_id).try(:name)
      return visit_data
    end

    # Build visit with all required fields
    visit = Visit.new
    
    # Required fields
    visit.patient_id = patient_id
    visit.visit_type_id = visit_params[:visit_type_id] 
    visit.date_started = visit_params[:date_started] || Time.now
    visit.date_created = visit_params[:date_created] || Time.now
    visit.creator = visit_params[:provider_id] || User.current&.user_id 
    visit.voided = false
    
    # Optional fields
    visit.date_stopped = visit_params[:date_stopped] if visit_params[:date_stopped].present?
    visit.location_id = visit_params[:location_id] if visit_params[:location_id].present?
    visit.indication_concept_id = visit_params[:indication_concept_id] if visit_params[:indication_concept_id].present?

    if visit.save
      visit_data = visit.attributes
      visit_data[:full_name] = Patient.find_by(patient_id: patient_id).try(:name)
      visit_data[:identifier] = identifier if identifier.present?

      if stage_params.present?
        data = StagesService.new.create_stage(stage_params)
        sync_to_couchdb(data, "stages", data[:identifier]) if data.present?
      end
      
      visit_data
    else
      Rails.logger.error("Visit creation failed: #{visit.errors.full_messages.join(', ')}")
      raise "Visit creation failed: #{visit.errors.full_messages.join(', ')}"
    end
  end

  def close_visit(visit_params)
    identifier = visit_params[:identifier]
    patient_id = nil

    if identifier.present?
      patient_identifier = PatientIdentifier.where(identifier: identifier).first
      patient_id = patient_identifier[:patient_id] if patient_identifier.present?
    end

    patient_id = visit_params[:patient_id] || visit_params[:patient_id] unless patient_id.present?

    visit = Visit.find_by(patient_id: patient_id, date_stopped: nil)

    unless visit.present?
      Rails.logger.warn("No open visit found for patient #{patient_id}")
      return
    end

    existing_stage = Stage.find_by(
      patient_id: visit.patient_id,
      location_id: visit_params[:location_id] || (User.current&.location_id)
    )
    existing_stage.destroy if existing_stage.present?

    closed_datetime = visit_params[:date_stopped] || Time.now

    visit.update(
      date_stopped: closed_datetime,
      changed_by: User.current&.user_id || 1,
      date_changed: Time.now
    )

    visit_data = visit.attributes
    visit_data[:identifier] = identifier if identifier.present?
    visit_data[:full_name] = Patient.find_by(patient_id: visit.patient_id).try(:name)
    visit_data
  end

  # ============================================================================
  # AETC Visit Service Methods
  # ============================================================================

  INITIAL_REGISTRATION = 'Initial Registration'
  SCREENING = 'Screening'
  SOCIAL_HISTORY = 'SOCIAL HISTORY'
  FINANCING = 'Financing'
  REFERRAL = 'REFERRAL'
  VITALS = 'Vitals'
  PRESENTING_COMPLAINTS = 'PRESENTING COMPLAINTS'
  AIRWAY_BREATHING = 'AIRWAY BREATHING'
  BLOOD_CIRCULATION = 'Blood Circulation'
  DISABILITY_ASSESSMENT = 'DISABILITY-ASSESSMENT'
  PERSISTENT_PAIN = 'Persistent Pain'
  TRIAGE_RESULT = 'Triage Result Observation'
  DISPOSITION = 'Disposition'

  INITIAL_REGISTRATION_ENCOUNTERS = [INITIAL_REGISTRATION].freeze
  SCREENING_ENCOUNTERS = [SCREENING].freeze
  REGISTRATION_ENCOUNTERS = [SOCIAL_HISTORY, FINANCING, REFERRAL].freeze
  TRIAGE_ENCOUNTERS = [VITALS, PRESENTING_COMPLAINTS,
                       AIRWAY_BREATHING, BLOOD_CIRCULATION, DISABILITY_ASSESSMENT,
                       PERSISTENT_PAIN].freeze
  DISPOSITION_ENCOUNTERS = [DISPOSITION].freeze

  SCREENS = {
    'screening' => INITIAL_REGISTRATION_ENCOUNTERS,
    'registration' => SCREENING_ENCOUNTERS,
    'triage' => REGISTRATION_ENCOUNTERS,
    'assessment' => TRIAGE_ENCOUNTERS,
    'disposition' => DISPOSITION_ENCOUNTERS
  }.freeze

  def self.last_obs_triage
    concept_id = ConceptName.find_by_name('Triage Result')&.concept_id

    <<-SQL
      SELECT obs.person_id, obs.value_text
      FROM obs
      WHERE obs.concept_id = #{concept_id}
      AND obs.obs_datetime = (
        SELECT MAX(o.obs_datetime)
        FROM obs o
        WHERE o.person_id = obs.person_id
        AND o.concept_id = #{concept_id}
    )
    SQL
  end

  def self.disposition_query(date: nil, open_visits_only: true, encounter_type_uuid: nil, patient_ids: [],
                             search: false)
    encounter_type_condition = encounter_type_uuid ? "encounter_type.uuid = '#{encounter_type_uuid}'" : '1=1'

    people = Patient.joins(encounters: [:type, :visit, { person: [:names] }])
                    .joins('INNER JOIN users ON users.user_id = encounter.creator')
                    .joins('INNER JOIN person_name le ON le.person_id = users.person_id')
                    .joins('INNER JOIN obs ON obs.encounter_id = encounter.encounter_id')
                    .where(visit: { visit_type_id: VisitType.where(name: 'AETC').pluck(:visit_type_id) })
                    .select(
                      'visit.patient_id',
                      'visit.uuid AS visit_uuid',
                      'GROUP_CONCAT(DISTINCT encounter_type.name) AS encounters_done',
                      'MIN(encounter.encounter_datetime) AS arrival_time',
                      'MAX(encounter.encounter_datetime) AS latest_encounter_time',
                      "MAX(CASE WHEN #{encounter_type_condition} THEN CONCAT(le.given_name, ' ', le.family_name) ELSE NULL END) AS last_encounter_creator",
                      'obs.value_text AS disposition_type'
                    )
                    .group('visit.patient_id', 'visit.uuid', 'disposition_type')

    people = people.where(visit: { date_created: 3.months.ago..Time.now }) unless search.present?
    people = people.where('visit.date_started BETWEEN ? AND ?', date.beginning_of_day, date.end_of_day) if date.present?
    people = people.where('visit.date_stopped IS NULL') if open_visits_only
    people = people.where('visit.patient_id IN (?)', patient_ids) if patient_ids.present?
    people = people.where(obs: { obs_group_id: nil })
    people.distinct
  end

  def self.visits_query(date: nil, open_visits_only: true, encounter_type_uuid: nil, patient_ids: [], search: false)
    concept_id = ConceptName.find_by_name('Triage Result')&.concept_id
    return Patient.none unless concept_id

    encounter_type_condition = encounter_type_uuid ? "encounter_type.uuid = '#{encounter_type_uuid}'" : '1=1'

    people = Patient.joins(encounters: [:type, :visit, { person: [:names] }])
                    .joins('INNER JOIN users ON users.user_id = encounter.creator')
                    .joins('INNER JOIN person_name le ON le.person_id = users.person_id')
                    .joins(<<-SQL)
                      LEFT JOIN (
                        SELECT obs.person_id, obs.value_text
                        FROM obs
                        INNER JOIN (
                          SELECT person_id, MAX(obs_datetime) AS latest_obs_datetime
                          FROM obs
                          WHERE concept_id = #{concept_id}
                          GROUP BY person_id
                        ) latest ON obs.person_id = latest.person_id AND obs.obs_datetime = latest.latest_obs_datetime
                        WHERE obs.concept_id = #{concept_id}
                      ) last_obs ON last_obs.person_id = visit.patient_id
                    SQL
                    .where(visit: { visit_type_id: VisitType.where(name: 'AETC').pluck(:visit_type_id) })
                    .select(
                      'visit.patient_id',
                      'visit.uuid AS visit_uuid',
                      'GROUP_CONCAT(DISTINCT encounter_type.name) AS encounters_done',
                      'MIN(encounter.encounter_datetime) AS arrival_time',
                      'MAX(encounter.encounter_datetime) AS latest_encounter_time',
                      "MAX(CASE WHEN #{encounter_type_condition} THEN CONCAT(le.given_name, ' ', le.family_name) ELSE NULL END) AS last_encounter_creator",
                      "CASE WHEN last_obs.value_text = 'red' THEN 1
                            WHEN last_obs.value_text = 'yellow' THEN 2 ELSE 3 END AS triage_result_priority"
                    )
                    .group('visit.patient_id', 'visit.uuid', 'last_obs.value_text')

    people = people.where(visit: { date_created: 3.months.ago..Time.now }) unless search.present? || date.present?
    people = people.where(visit: { date_started: date.beginning_of_day..date.end_of_day }) if date.present?
    people = people.where(visit: { date_stopped: nil }) if open_visits_only
    people = people.where(visit: { patient_id: patient_ids }) if patient_ids.present? || search.present?
    people
  end

  def self.daily_visits(date: nil, category: nil, open_visits_only: true, patient_ids: [], search: false)
    date = date.to_date if date.present?
    ActiveRecord::Base.transaction do
      if category == 'disposition'
        patients = disposition_query(date:, open_visits_only:, patient_ids:, search:)
      else
        patients = visits_query(date:, open_visits_only:, patient_ids:, search:)
        patients = patients.order(Arel.sql('triage_result_priority, arrival_time')) if category == 'assessment'
      end

      patients.select { |patient| eligible?(category, patient) }
    end
  end

  def self.eligible?(category, patient)
    raise 'Invalid category' unless SCREENS.keys.include?(category)

    %i[on_screening_for_less_than_24hrs? all_previous_encounters_completed?
       next_encounters_incomplete?].all? do |method|
      send(method, category, patient)
    end
  end

  def self.find_visits(params)
    patient_ids = patient_ids(params)
    search = params.include?('search') && params[:search].present?

    if params.include?('category')
      return daily_visits(date: params[:date], category: params[:category], patient_ids:, search:)
    end

    visits = Visit.all
    params.each do |key, value|
      next unless Visit.column_names.include?(key)

      if key.include?('date')
        visits = visits.where("DATE(visit.#{key}) = ?", value&.to_date) unless value.nil? || value.empty?
        visits = visits.where(key => nil) if value.nil? || value.empty?
        next
      end
      visits = visits.where(key => value)
    end
    visits
  end

  def self.eligible_for_assessment(params)
    return false unless params.include?('category')

    patient_ids = patient_ids(params)
    return false if patient_ids.empty?

    visits = find_visits(params)
    !visits.empty?
  end

  def self.patient_ids(params)
    patient_ids = []
    if params.include?('search') && params[:search].present?
      patient_ids = Patient.where(patient_id: Person.where(person_id: PersonNameService.search(params[:search].strip).pluck(:person_id)).ids).ids
    end
    if params.include?('patient_id')
      patient_ids = Patient.where(patient_id: params[:patient_id]).ids
      patient_ids = Patient.joins(:person).where({ person: { uuid: params[:patient_id] } }).ids if patient_ids.empty?
    end
    patient_ids
  end

  private_class_method def self.all_previous_encounters_completed?(category, patient)
    SCREENS[category].all? { |encounter| patient.encounters_done.downcase.split(',').include?(encounter.downcase) }
  end

  private_class_method def self.next_encounters_incomplete?(category, patient)
    return true if next_encounters(category).nil?

    !(next_encounters(category).all? do |encounter|
      patient.encounters_done.downcase.split(',').include?(encounter.downcase)
    end)
  end

  private_class_method def self.on_screening_for_less_than_24hrs?(category, patient)
    return true unless category == 'screening'

    patient_open_visit = Visit.find_by(patient_id: patient.id, date_stopped: nil)
    initial_reg_encounter = Encounter.find_by(
      patient_id: patient.id,
      encounter_type: EncounterType.find_by_name(INITIAL_REGISTRATION)
    )

    return true unless initial_reg_encounter
    return true if patient_open_visit.nil?

    if patient_open_visit.date_started < 48.hours.ago
      reason = Observation.new
      reason.person_id = patient.patient_id
      reason.concept_id = ConceptName.find_by_name('Reason for exiting care')&.concept_id
      reason.value_text = 'Screening took more than 24 hours'
      reason.encounter_id = initial_reg_encounter.encounter_id
      reason.obs_datetime = Time.now
      reason.creator = User.current.user_id
      reason.date_created = Time.now
      reason.save!

      patient_open_visit.date_stopped = Time.now
      patient_open_visit.changed_by = User.current.user_id
      patient_open_visit.date_changed = Time.now
      patient_open_visit.save!

      return false
    end

    true
  end

  private_class_method def self.next_encounters(category)
    SCREENS[next_category(category)]
  end

  private_class_method def self.next_category(category)
    keys = SCREENS.keys
    index = keys.index(category)
    return nil if index.nil? || index == keys.length - 1

    keys[index + 1]
  end
end
