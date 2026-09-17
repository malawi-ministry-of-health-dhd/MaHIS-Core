# frozen_string_literal: true
#
# Backfill for the gap fixed in PatientRecordService::ObservationSaver
# (#sync_hiv_program_state_from_treatment_status): the ART "Change outcome"
# UI records an outcome (Patient died / transferred out / stopped / etc.) as a
# "Treatment status" observation, but before that fix nothing ever created the
# matching patient_state row. Reports that derive cumulative outcome from
# patient_state (TX_ML and friends — see ArtService::Reports::Cohort::Outcomes)
# never saw these outcomes even though they were visible on the patient profile.
#
# This walks every "Treatment status" observation recorded under an HIV
# program encounter, and creates any patient_state transition that is missing,
# in chronological order per patient — exactly what the live fix now does at
# save time. It is scoped to encounter.program_id == HIV program, matching the
# live fix's scoping, so an observation filed under a different program can
# never touch a patient's HIV program state.
#
# Idempotent: an observation whose (state, start_date) pair already exists as
# a patient_state is skipped, so re-running only fills in what's still missing.
#
# patient_state only has day precision. If backfilling a missing observation
# would require closing a same-day (or later-dated) state that's already
# open, and it can't confirm from the real obs_datetime that the open state
# genuinely comes first, it refuses to guess — it logs "NEEDS REVIEW" and
# leaves that one for a human to fix directly, rather than risk silently
# reversing the true chronological order.
#
# Usage:
#   bin/rails art:backfill_hiv_program_states                     # dry run, all patients
#   DRY_RUN=false bin/rails art:backfill_hiv_program_states        # write
#   DRY_RUN=false PATIENT_ID=7 bin/rails art:backfill_hiv_program_states
#   LIMIT=100 bin/rails art:backfill_hiv_program_states            # cap patients scanned
class HivProgramStateBackfillTask
  TREATMENT_STATUS_CONCEPT_NAME = 'Treatment status'
  HIV_PROGRAM_NAME = 'HIV Program'

  def initialize(env = ENV)
    @dry_run = env.fetch('DRY_RUN', 'true').to_s.downcase != 'false'
    @patient_id = env['PATIENT_ID'].presence&.to_i
    @limit = positive_integer(env['LIMIT'])

    @patients_scanned = 0
    @patients_updated = 0
    @patients_already_synced = 0
    @patients_failed = 0
    @patients_needing_review = 0
    @states_created = 0
  end

  def run
    raise "Program '#{HIV_PROGRAM_NAME}' not found" unless hiv_program
    raise "Concept '#{TREATMENT_STATUS_CONCEPT_NAME}' not found" unless treatment_status_concept_id

    puts "\n===== HIV Program patient_state Backfill (from Treatment status observations) ====="
    puts "Mode: #{@dry_run ? 'DRY RUN (report only)' : 'WRITE'}"
    puts "Patient: #{@patient_id}" if @patient_id
    puts "Limit: #{@limit}" if @limit
    puts

    candidate_patient_ids.each do |patient_id|
      break if @limit && @patients_scanned >= @limit

      @patients_scanned += 1
      backfill_patient(patient_id)
    end

    puts "\n===== Backfill Summary ====="
    puts "Patients scanned:        #{@patients_scanned}"
    puts "Patients updated:        #{@patients_updated}"
    puts "Patients already synced: #{@patients_already_synced}"
    puts "Patients needing review: #{@patients_needing_review}"
    puts "Patients failed:         #{@patients_failed}"
    puts "patient_state rows created: #{@states_created}"
    puts(@dry_run ? "\nDry run only. Re-run with DRY_RUN=false to write." : "\nDone.")
  end

  private

  def candidate_patient_ids
    scope = base_observation_scope.distinct.order(:person_id)
    scope = scope.where(person_id: @patient_id) if @patient_id
    scope.pluck(:person_id)
  end

  def base_observation_scope
    Observation.joins(:encounter)
               .where(concept_id: treatment_status_concept_id, voided: 0)
               .where.not(value_coded: nil)
               .where(encounter: { program_id: hiv_program.program_id, voided: 0 })
  end

  def backfill_patient(patient_id)
    patient = Patient.find_by(patient_id: patient_id)
    unless patient
      log(patient_id, 'SKIP (patient not found)')
      @patients_failed += 1
      return
    end

    patient_program = PatientProgram.where(patient_id: patient_id, program: hiv_program, voided: 0)
                                    .order(:date_enrolled).last
    unless patient_program
      log(patient_id, 'SKIP (no HIV patient_program — patient was never enrolled)')
      @patients_failed += 1
      return
    end

    observations = base_observation_scope.where(person_id: patient_id).order(:obs_datetime, :obs_id).to_a
    existing_states = PatientState.where(patient_program: patient_program, voided: 0)
                                  .pluck(:state, :start_date).to_set
    obs_datetime_by_state_and_date = index_observations_by_state_and_date(observations)

    created_for_patient, flagged_for_patient =
      process_observations(patient, patient_program, observations, existing_states, obs_datetime_by_state_and_date)

    @patients_needing_review += 1 if flagged_for_patient.positive?

    if created_for_patient.positive?
      @patients_updated += 1
      @states_created += created_for_patient
    elsif flagged_for_patient.zero?
      @patients_already_synced += 1
    end
  rescue StandardError => e
    @patients_failed += 1
    log(patient_id, "FAILED - #{e.class}: #{e.message}")
  end

  # patient_state.start_date/end_date only carry day precision, so once two
  # outcome changes land on the same calendar day, PatientStateService's
  # "close whatever is currently open" logic can't tell which one is really
  # earlier — it would happily close the wrong one and reverse their order.
  # This indexes each (workflow_state_id, date) this patient's own Treatment
  # status observations produce against the real obs_datetime that produced
  # it, so we can tell same-day transitions apart by actual time of day.
  def index_observations_by_state_and_date(observations)
    index = {}

    observations.each do |obs|
      workflow_state_id = hiv_program_workflow_state_id(obs.value_coded)
      date = obs.obs_datetime&.to_date
      next unless workflow_state_id && date

      key = [workflow_state_id, date]
      index[key] = obs.obs_datetime if index[key].nil? || obs.obs_datetime > index[key]
    end

    index
  end

  # Returns [states_created, states_flagged_for_review]. Runs through
  # PatientStateService#create_patient_state for real — even in dry-run,
  # wrapped in a transaction that is always rolled back — so the dry-run
  # report reflects the exact same close-current/open-new behavior the write
  # path performs, instead of a hand-rolled approximation.
  def process_observations(patient, patient_program, observations, existing_states, obs_datetime_by_state_and_date)
    created = 0
    flagged = 0

    ActiveRecord::Base.transaction do
      observations.each do |obs|
        workflow_state_id = hiv_program_workflow_state_id(obs.value_coded)
        unless workflow_state_id
          log(patient.patient_id, "obs #{obs.obs_id} SKIP (value_coded=#{obs.value_coded} is not an HIV workflow state)")
          next
        end

        date = obs.obs_datetime&.to_date
        unless date
          log(patient.patient_id, "obs #{obs.obs_id} SKIP (missing obs_datetime)")
          next
        end

        next if existing_states.include?([workflow_state_id, date])

        open_state = PatientState.where(patient_program: patient_program, voided: 0, end_date: nil)
                                 .order(:patient_state_id).last

        if open_state && same_day_ordering_conflict?(open_state, date, obs.obs_datetime, obs_datetime_by_state_and_date)
          log(patient.patient_id,
              "obs #{obs.obs_id} NEEDS REVIEW - would close state=#{open_state.state} (#{state_name(open_state.state)}) " \
              "start_date=#{open_state.start_date}, which patient_state's day-only precision can't confirm is earlier " \
              "than this observation (#{obs.obs_datetime}) - fix manually, not auto-applying")
          flagged += 1
          next
        end

        verb = @dry_run ? 'WOULD CREATE' : 'created'
        log(patient.patient_id,
            "#{verb} state=#{workflow_state_id} (#{state_name(workflow_state_id)}) start_date=#{date} (from obs #{obs.obs_id})")

        with_acting_user(obs.creator) do
          PatientStateService.new.create_patient_state(hiv_program, patient, workflow_state_id, date)
        end
        existing_states << [workflow_state_id, date]
        created += 1
      end

      raise ActiveRecord::Rollback if @dry_run
    end

    [created, flagged]
  end

  def same_day_ordering_conflict?(open_state, date, obs_datetime, obs_datetime_by_state_and_date)
    return true if open_state.start_date > date
    return false if open_state.start_date < date

    predecessor_obs_datetime = obs_datetime_by_state_and_date[[open_state.state, open_state.start_date]]
    predecessor_obs_datetime.present? && predecessor_obs_datetime > obs_datetime
  end

  # A rake run has no authenticated session, so User.current starts nil —
  # PatientState.create would crash in Auditable#update_create_trail without
  # this. Attribute the backfilled state to whoever actually recorded the
  # observation (its creator), which is also more historically accurate than
  # attributing it to whoever happens to run the backfill.
  def with_acting_user(creator_id)
    previous_user = User.current
    User.current = User.unscoped.find_by(user_id: creator_id) if creator_id.to_i.positive?
    yield
  ensure
    User.current = previous_user
  end

  def treatment_status_concept_id
    @treatment_status_concept_id ||= ConceptName.find_by(name: TREATMENT_STATUS_CONCEPT_NAME, voided: 0)&.concept_id
  end

  def hiv_program
    @hiv_program ||= Program.find_by(name: HIV_PROGRAM_NAME)
  end

  def hiv_program_workflow_state_id(value_coded)
    return nil if value_coded.blank?

    @workflow_state_cache ||= {}
    @workflow_state_cache.fetch(value_coded.to_i) do
      @workflow_state_cache[value_coded.to_i] = ProgramWorkflowState.joins(:program_workflow)
                                                                    .where(concept_id: value_coded.to_i, retired: 0)
                                                                    .where(program_workflow: { program_id: hiv_program.program_id, retired: 0 })
                                                                    .pick(:program_workflow_state_id)
    end
  end

  def state_name(workflow_state_id)
    @state_name_cache ||= {}
    @state_name_cache[workflow_state_id] ||= ProgramWorkflowState.find(workflow_state_id).name
  end

  def log(patient_id, message)
    puts "  patient #{patient_id}: #{message}"
  end

  def positive_integer(value)
    return nil if value.blank?

    parsed = value.to_i
    parsed.positive? ? parsed : nil
  end
end

namespace :art do
  desc 'Backfill missing HIV program patient_state rows for existing "Treatment status" outcome observations'
  task backfill_hiv_program_states: :environment do
    HivProgramStateBackfillTask.new.run
  end
end
