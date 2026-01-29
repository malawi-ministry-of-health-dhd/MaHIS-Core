# frozen_string_literal: true
module NeonatalService
  class PatientsEngine
    include ModelUtils

    attr_reader :program

    STAT_STATUSES = {
      enrolled: 'In patient',
      admitted: 'Admitted',
      discharged: 'Discharged',
      critical: 'Critical',
      triage_only: 'Triage Only - Pending Registration'
    }.freeze

    def initialize(program:)
      @program = program
    end

    def saved_encounters(patient, _date = nil)
      patient_id = patient.patient_id || patient.id

      Encounter.joins(:type)
               .where(program_id: @program.program_id, patient_id: patient_id, voided: 0)
               .order(:encounter_datetime)
               .pluck('encounter_type.name')
               .uniq
    end

    def statistics(date = Date.today)
      {
        enrolled: build_statistic_from_programs(patients_enrolled_on(date), date, STAT_STATUSES[:enrolled]),
        admitted: build_statistic(patients_admitted_on(date), date, STAT_STATUSES[:admitted]),
        discharged: build_statistic_from_programs(patients_discharged_on(date), date, STAT_STATUSES[:discharged]),
        critical: build_statistic(critical_patients(date), date, STAT_STATUSES[:critical]),
        triage_only: build_statistic(triage_only_patients(date), date, STAT_STATUSES[:triage_only]),
        recent_neonates: get_recent_neonates(date)
      }
    end

    def get_recent_neonates(date = Date.today, limit = 10)
      start_date = date.to_date - 7.days
      end_date = date.to_date

      recent_patients = Encounter
        .select('patient.*, person.birthdate, MAX(encounter.encounter_datetime) as last_encounter_time')
        .joins(:patient)
        .joins('INNER JOIN person ON person.person_id = patient.patient_id')
        .joins("INNER JOIN patient_program ON patient_program.patient_id = patient.patient_id
                AND patient_program.program_id = #{@program.program_id}
                AND patient_program.voided = 0
                AND (patient_program.date_completed IS NULL OR patient_program.date_completed >= '#{date.to_date}')")
        .where('encounter.program_id = ?', @program.program_id)
        .where('encounter.voided = ?', 0)
        .where('DATE(encounter.encounter_datetime) BETWEEN ? AND ?', start_date, end_date)
        .where('person.birthdate IS NOT NULL')
        .where('DATEDIFF(?, person.birthdate) <= ?', date.to_date, 28)
        .group('patient.patient_id')
        .order('last_encounter_time DESC')
        .limit(limit)
        .map(&:patient)
        .compact

      recent_patients.map do |patient|
        status = determine_patient_status(patient, date)
        format_neonate(patient, status, date)
      end
    end

    private

    def determine_patient_status(patient, date)
      program = PatientProgram.find_by(
        patient_id: patient.patient_id,
        program_id: @program.program_id
      )

      return STAT_STATUSES[:discharged] if program && program.date_completed && program.date_completed <= date

      triage_concept = concept('Triage priority')
      emergency_value = concept('Emergency')

      if triage_concept && emergency_value
        has_emergency = Observation
          .joins(:encounter)
          .where(encounter: { patient_id: patient.patient_id, program_id: @program.program_id, voided: 0 })
          .where(voided: 0, concept_id: triage_concept.concept_id, value_coded: emergency_value.concept_id)
          .where('DATE(obs_datetime) >= ?', date - 1.day)
          .exists?

        return STAT_STATUSES[:critical] if has_emergency
      end

      admission_encounter_names = [
        'NEONATAL SIGNS & SYMPTOMS',
        'NEONATAL REVIEW OF SYSTEMS',
        'PHYSICAL EXAMINATION BABY',
        'NEONATAL GENERAL EXAMINATION',
        'VITALS',
        'NEONATAL VITALS',
        'NEONATAL SYSTEMIC EXAMINATION'
      ]

      encounter_types = EncounterType.where(name: admission_encounter_names)
      if encounter_types.any?
        has_admission_encounter_today = Encounter
          .where(patient_id: patient.patient_id, program_id: @program.program_id)
          .where(encounter_type: encounter_types.pluck(:encounter_type_id), voided: 0)
          .where('DATE(encounter_datetime) = ?', date)
          .exists?

        return STAT_STATUSES[:admitted] if has_admission_encounter_today
      end

      STAT_STATUSES[:enrolled]
    end

    def patients_enrolled_on(date)
      PatientProgram.joins(:patient)
                    .where(program_id: @program.program_id)
                    .where('DATE(date_enrolled) = ?', date.to_date)
                    .includes(patient: { person: :names })
    end

    def patients_discharged_on(date)
      PatientProgram.joins(:patient)
                    .where(program_id: @program.program_id)
                    .where.not(date_completed: nil)
                    .where('DATE(date_completed) = ?', date.to_date)
                    .includes(patient: { person: :names })
    end

    def patients_admitted_on(date)
      admission_encounter_names = [
        'NEONATAL SIGNS & SYMPTOMS',
        'NEONATAL REVIEW OF SYSTEMS',
        'PHYSICAL EXAMINATION BABY',
        'NEONATAL GENERAL EXAMINATION',
        'VITALS',
        'NEONATAL VITALS',
        'NEONATAL SYSTEMIC EXAMINATION'
      ]

      encounter_types = EncounterType.where(name: admission_encounter_names)
      return [] if encounter_types.empty?

      Encounter.where(program_id: @program.program_id, encounter_type: encounter_types.pluck(:encounter_type_id), voided: 0)
               .where('DATE(encounter_datetime) = ?', date.to_date)
               .includes(:patient)
               .map(&:patient)
               .compact
               .uniq { |patient| patient.patient_id }
    end

    def critical_patients(date)
      triage_concept = concept('Triage priority')
      emergency_value = concept('Emergency')
      return [] unless triage_concept && emergency_value

      Observation.joins(:encounter)
                 .where(encounter: { program_id: @program.program_id, voided: 0 })
                 .where(voided: 0)
                 .where(concept_id: triage_concept.concept_id, value_coded: emergency_value.concept_id)
                 .where('DATE(obs_datetime) = ?', date.to_date)
                 .includes(encounter: :patient)
                 .map { |obs| obs.encounter.patient }
                 .compact
                 .uniq { |patient| patient.patient_id }
    end

    def triage_only_patients(date)
      triage_encounter_type = EncounterType.find_by(name: 'NEONATAL TRIAGE')
      return [] unless triage_encounter_type

      patients_with_triage = Encounter
        .where(program_id: @program.program_id, encounter_type: triage_encounter_type.encounter_type_id, voided: 0)
        .where('DATE(encounter_datetime) = ?', date.to_date)
        .includes(:patient)
        .map(&:patient)
        .compact
        .uniq { |patient| patient.patient_id }

      patients_with_triage.select do |patient|
        person = patient.person
        next false unless person

        has_minimal_demographics = person.birthdate_estimated == 1 && person.gender == 'U'
        next false unless has_minimal_demographics

        other_encounter_types = [
          'NEONATAL ENROLLMENT',
          'NEONATAL SIGNS & SYMPTOMS',
          'NEONATAL REVIEW OF SYSTEMS',
          'PHYSICAL EXAMINATION BABY',
          'NEONATAL GENERAL EXAMINATION',
          'NEONATAL VITALS',
          'NEONATAL SYSTEMIC EXAMINATION'
        ]

        encounter_types = EncounterType.where(name: other_encounter_types)
        has_other_encounters = Encounter
          .where(patient_id: patient.patient_id, program_id: @program.program_id, voided: 0)
          .where(encounter_type: encounter_types.pluck(:encounter_type_id))
          .exists?

        !has_other_encounters
      end
    end

    def build_statistic_from_programs(program_relation, date, status)
      patients = program_relation.map(&:patient).compact
      build_statistic(patients, date, status)
    end

    def build_statistic(patients, date, status)
      unique_patients = patients.compact.uniq { |patient| patient.patient_id }
      {
        count: unique_patients.length,
        neonates: unique_patients.map { |patient| format_neonate(patient, status, date) }
      }
    end

    def format_neonate(patient, status, date)
      person = patient.person
      {
        id: patient.patient_id,
        name: formatted_name(person),
        mrn: patient_identifier_value(patient),
        age: format_age(person, date),
        weight: format_weight(patient, date),
        status: status
      }
    end

    def formatted_name(person)
      return 'Unknown Neonate' unless person

      name = person.names.first
      parts = [name&.given_name, name&.middle_name, name&.family_name].compact.map(&:strip).reject(&:blank?)
      value = parts.join(' ')
      value.present? ? value : 'Unknown Neonate'
    end

    def patient_identifier_value(patient)
      identifier = patient.national_id
      return identifier if identifier.present?

      patient.patient_identifiers.order(:date_created).last&.identifier || 'N/A'
    end

    def format_age(person, date)
      return 'Unknown' unless person&.birthdate

      reference_date = date.to_date
      age_days = (reference_date - person.birthdate).to_i
      return 'Today' if age_days.zero?
      return "#{age_days} day#{'s' unless age_days == 1} old" if age_days.positive? && age_days < 30

      weeks = (age_days / 7.0).floor
      if weeks.positive? && weeks < 4
        "#{weeks} week#{'s' unless weeks == 1} old"
      else
        "#{age_days} day#{'s' unless age_days == 1} old"
      end
    end

    def format_weight(patient, date)
      value = patient.weight(today: date)
      return nil unless value

      format('%.2f Kg', value)
    end
  end
end
