# frozen_string_literal: true

# Voids active patient rows that cannot produce a CouchDB patient document and
# have never been enrolled in a program. It intentionally leaves person and
# clinical tables unchanged so the operation remains auditable and recoverable.
class VoidUnsyncablePatientsTask
  SAFE_CONFIRMATION = 'VOID_UNSYNCABLE_PATIENTS'
  CLINICAL_CONFIRMATION = 'VOID_PATIENTS_WITH_CLINICAL_DATA'
  DEFAULT_BATCH_SIZE = 5_000
  VOID_REASON = 'No valid type-3 identifier and no patient program enrollment'

  MISSING_TYPE3_SQL = <<~SQL.squish.freeze
    NOT EXISTS (
      SELECT 1
      FROM patient_identifier cleanup_identifier
      WHERE cleanup_identifier.patient_id = patient.patient_id
        AND cleanup_identifier.identifier_type = 3
        AND cleanup_identifier.voided = 0
        AND cleanup_identifier.identifier IS NOT NULL
        AND cleanup_identifier.identifier <> ''
    )
  SQL

  NO_PROGRAM_SQL = <<~SQL.squish.freeze
    NOT EXISTS (
      SELECT 1
      FROM patient_program cleanup_program
      WHERE cleanup_program.patient_id = patient.patient_id
    )
  SQL

  NO_CLINICAL_DATA_SQL = <<~SQL.squish.freeze
    NOT EXISTS (
      SELECT 1 FROM encounter cleanup_encounter
      WHERE cleanup_encounter.patient_id = patient.patient_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM obs cleanup_observation
      WHERE cleanup_observation.person_id = patient.patient_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM orders cleanup_order
      WHERE cleanup_order.patient_id = patient.patient_id
    )
  SQL

  def initialize(env = ENV)
    @apply = env['APPLY'].to_s == '1'
    @include_clinical = env['INCLUDE_CLINICAL'].to_s == '1'
    @confirmation = env['CONFIRM'].to_s
    @voided_by = env['VOIDED_BY'].presence&.to_i
    @batch_size = positive_integer(env['BATCH_SIZE'], DEFAULT_BATCH_SIZE)

    validate_options!
  end

  def run
    all_candidates = base_scope.count
    empty_candidates = safe_scope.count
    clinical_candidates = all_candidates - empty_candidates
    selected_count = @include_clinical ? all_candidates : empty_candidates

    print_report(all_candidates, empty_candidates, clinical_candidates, selected_count)
    return print_dry_run_help unless @apply

    void_candidates(selected_count)
  end

  private

  def positive_integer(value, fallback)
    parsed = value.to_i
    parsed.positive? ? parsed : fallback
  end

  def validate_options!
    return unless @apply

    required_confirmation =
      @include_clinical ? CLINICAL_CONFIRMATION : SAFE_CONFIRMATION
    unless @confirmation == required_confirmation
      raise ArgumentError, "CONFIRM=#{required_confirmation} is required"
    end

    raise ArgumentError, 'VOIDED_BY is required when APPLY=1' if @voided_by.blank?
    return if User.unscoped.exists?(user_id: @voided_by)

    raise ArgumentError, "VOIDED_BY user #{@voided_by} was not found"
  end

  def base_scope
    Patient.unscoped
           .where(voided: 0)
           .where(MISSING_TYPE3_SQL)
           .where(NO_PROGRAM_SQL)
  end

  def safe_scope
    base_scope.where(NO_CLINICAL_DATA_SQL)
  end

  def target_scope
    @include_clinical ? base_scope : safe_scope
  end

  def print_report(all_candidates, empty_candidates, clinical_candidates, selected_count)
    puts "\n===== Unsyncable Patient Cleanup ====="
    puts 'Criteria: active patient, no valid type-3 identifier, no patient_program row'
    puts "All matching patients: #{all_candidates}"
    puts "Without encounters, observations, or orders: #{empty_candidates}"
    puts "With clinical data (protected by default): #{clinical_candidates}"
    puts "Mode: #{@include_clinical ? 'INCLUDE CLINICAL DATA' : 'EMPTY PATIENTS ONLY'}"
    puts "Action: #{@apply ? 'VOID PATIENTS' : 'DRY RUN'}"
    puts "Selected patients: #{selected_count}"
    puts "Batch size: #{@batch_size}"
    sample_ids = target_scope.order(:patient_id).limit(20).pluck(:patient_id)
    puts "Sample IDs: #{sample_ids.join(', ')}" if sample_ids.any?
    puts
  end

  def print_dry_run_help
    puts 'No records changed.'
    if @include_clinical
      puts "Apply all matching patients with: APPLY=1 INCLUDE_CLINICAL=1 CONFIRM=#{CLINICAL_CONFIRMATION} VOIDED_BY=<user_id>"
    else
      puts "Apply empty patients with: APPLY=1 CONFIRM=#{SAFE_CONFIRMATION} VOIDED_BY=<user_id>"
    end
  end

  def void_candidates(selected_count)
    voided_at = Time.current
    last_patient_id = 0
    total_voided = 0

    loop do
      ids = target_scope
            .where('patient.patient_id > ?', last_patient_id)
            .order(:patient_id)
            .limit(@batch_size)
            .pluck(:patient_id)
      break if ids.empty?

      # Reapply every eligibility predicate during the update so a patient that
      # concurrently receives an identifier, program, or clinical record is not
      # voided from a stale candidate list.
      updated = target_scope.where(patient_id: ids).update_all(
        voided: 1,
        voided_by: @voided_by,
        date_voided: voided_at,
        void_reason: VOID_REASON
      )
      total_voided += updated
      last_patient_id = ids.last
      puts "Voided #{total_voided}/#{selected_count} patient(s)"
    end

    puts "\nCompleted. Voided #{total_voided} patient(s)."
    puts 'No patient, person, identifier, program, encounter, observation, or order rows were deleted.'
  end
end
