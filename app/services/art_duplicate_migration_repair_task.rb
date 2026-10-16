# frozen_string_literal: true

# Runs the ART duplicate rollback and demographic repair in the required order.
class ArtDuplicateMigrationRepairTask
  CONFIRMATION = 'RESTORE_ART_DUPLICATE_MIGRATION_DATA'
  TRUTHY = %w[1 true yes y].freeze

  def initialize(env = ENV, rollback_task_class: ArtDuplicateMergeRollbackTask,
                 demographics_task_class: ArtMissingDemographicsRepairTask)
    @env = env.to_h
    @apply = truthy?(@env['APPLY'])
    @approve_all = truthy?(@env['APPROVE_ALL'])
    @confirmation = @env['CONFIRM'].to_s
    @operator_user_id = @env['USER_ID'].to_i
    @rollback_task_class = rollback_task_class
    @demographics_task_class = demographics_task_class
    validate_options!
  end

  def run
    puts "\n===== ART Duplicate Migration Repair ====="
    puts 'Step 1 of 2: duplicate merge rollback'
    @rollback_task_class.new(child_env(ArtDuplicateMergeRollbackTask::CONFIRMATION)).run

    puts "\nStep 2 of 2: missing or invalid demographics repair"
    @demographics_task_class.new(child_env(ArtMissingDemographicsRepairTask::CONFIRMATION)).run
    puts "\nART duplicate migration repair completed."
  end

  private

  def validate_options!
    return unless @apply

    raise ArgumentError, 'APPROVE_ALL=1 is required' unless @approve_all
    raise ArgumentError, "CONFIRM=#{CONFIRMATION} is required" unless @confirmation == CONFIRMATION
    raise ArgumentError, 'USER_ID must identify the operator' unless @operator_user_id.positive?
  end

  def child_env(confirmation)
    @env.merge('CONFIRM' => confirmation)
  end

  def truthy?(value)
    TRUTHY.include?(value.to_s.downcase)
  end
end
