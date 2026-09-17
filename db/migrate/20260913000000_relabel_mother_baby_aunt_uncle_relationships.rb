# frozen_string_literal: true

# The labour/PNC "link the newborn to the mother" flows hardcoded relationship
# type 32 on the assumption that 32 meant "Child". In this database 32 is
# Aunt/Uncle <-> Niece/Nephew, so every baby linked at delivery was recorded as
# the mother's niece/nephew. The flows now pass the Parent <-> Child type (see
# CHILD_RELATIONSHIP_TYPE_ID in the client's relationship_service.ts); this
# migration relabels the rows the old code already wrote.
#
# The catch is that 32 is also a perfectly valid pick in the registration and
# Add Relationship forms, so the type alone says nothing. A blanket UPDATE would
# turn real aunts and uncles into parents. Rows are therefore matched on what
# only the delivery flows produce:
#
#   * person_b is a live Patient. A guardian or next-of-kin captured on the
#     registration form is created as a bare Person (no gender, no birthdate,
#     never a patient row), which is what the overwhelming majority of these
#     rows are.
#   * person_b was a newborn when the link was made - born no more than
#     MAX_BABY_AGE_DAYS before date_created. That is the same 7-week window the
#     client uses for "babies from the latest delivery".
#   * person_a is enrolled in LABOUR AND DELIVERY or PNC. Those flows only run
#     inside those programs, and a save there cannot happen without enrolment.
#
# Relationship types and programs are resolved by label rather than by id: ids
# are not portable between installations (that is the bug being fixed here), so
# a site whose 32 is not Aunt/Uncle is left alone instead of corrupted.
#
# Rows the type matches but the rule declines are reported, not touched, so a
# reviewer can see what was deliberately left behind.
class RelabelMotherBabyAuntUncleRelationships < ActiveRecord::Migration[8.1]
  REQUIRED_TABLES = %i[relationship relationship_type person patient patient_program program].freeze

  # What the old client code wrote, and what the type has to mean for this
  # installation to be the one the bug applies to.
  MISLABELLED_TYPE_ID = 32
  MISLABELLED_A_IS_TO_B = 'Aunt/Uncle'
  MISLABELLED_B_IS_TO_A = 'Niece/Nephew'

  # What the link should have said: person_a (the mother) is Parent to person_b.
  CORRECT_A_IS_TO_B = 'Parent'
  CORRECT_B_IS_TO_A = 'Child'

  # Matches MAX_PNC_BABY_AGE_DAYS on the client - the age at which a linked baby
  # stops counting as "from the latest delivery".
  MAX_BABY_AGE_DAYS = 49

  DELIVERY_PROGRAM_NAMES = ['LABOUR AND DELIVERY PROGRAM', 'PNC PROGRAM'].freeze

  # Refreshes the CouchDB copies of the relabelled records. See
  # trigger_patient_document_rebuild for why this is a full rebuild.
  REBUILD_TASK = 'sync:all'
  REBUILD_TASK_ARGUMENT = 'rebuild_patients'

  def up
    return say('Skipped: expected tables are not present.') unless required_tables_present?

    mislabelled_type_id = mislabelled_relationship_type_id
    return say("Skipped: relationship type #{MISLABELLED_TYPE_ID} is not " \
               "#{MISLABELLED_A_IS_TO_B}/#{MISLABELLED_B_IS_TO_A} here, so the delivery flows " \
               'never wrote it. Nothing to relabel.') unless mislabelled_type_id

    correct_type_id = correct_relationship_type_id
    return say("Skipped: no #{CORRECT_A_IS_TO_B}/#{CORRECT_B_IS_TO_A} relationship type exists; " \
               'there is nothing to relabel these links to.') unless correct_type_id

    declined = declined_rows(mislabelled_type_id)
    if declined.any?
      say("Leaving #{declined.size} #{MISLABELLED_A_IS_TO_B} link(s) alone - they point at a " \
          'patient but do not look like a delivery link:')
      declined.each do |row|
        say("relationship #{row['relationship_id']}: person_a=#{row['person_a']} " \
            "person_b=#{row['person_b']} created=#{row['date_created']} " \
            "person_b_birthdate=#{row['birthdate'] || 'none'}", true)
      end
    end

    rows = mother_baby_rows(mislabelled_type_id)
    return say('No mislabelled mother-baby links found.') if rows.empty?

    say("Relabelling #{rows.size} mother-baby link(s) from type #{mislabelled_type_id} " \
        "(#{MISLABELLED_A_IS_TO_B}) to #{correct_type_id} (#{CORRECT_A_IS_TO_B}):")
    rows.each do |row|
      say("relationship #{row['relationship_id']}: mother=#{row['person_a']} " \
          "baby=#{row['person_b']} born=#{row['birthdate']} linked=#{row['date_created']}", true)
    end

    relationship_ids = rows.map { |row| row['relationship_id'].to_i }
    execute(<<~SQL.squish)
      UPDATE relationship
      SET relationship = #{correct_type_id}
      WHERE relationship_id IN (#{relationship_ids.join(',')})
    SQL

    say("To undo, set relationship back to #{mislabelled_type_id} for relationship_id IN " \
        "(#{relationship_ids.join(',')}).", true)

    patient_ids = rows.flat_map { |row| [row['person_a'].to_i, row['person_b'].to_i] }.uniq.sort
    trigger_patient_document_rebuild(patient_ids)
  end

  # Once relabelled, these rows are indistinguishable from the Parent/Child links
  # the fixed code writes for every new delivery, so a selector-based revert would
  # take legitimate rows with it. The ids and the exact revert are printed by up.
  def down
    raise ActiveRecord::IrreversibleMigration,
          'Relabelled mother-baby links cannot be told apart from correctly created ' \
          'Parent/Child links afterwards. Revert with the relationship_id list printed by up.'
  end

  private

  # CouchDB copies keep the old label until their record is rebuilt, so the sync
  # is kicked off from here rather than left as a manual follow-up. Three things
  # it needs to survive running inside db:migrate:
  #
  #   * WATCH=0. The task otherwise ends on SyncDashboard#watch, which blocks
  #     until Ctrl-C, and nobody is at a terminal during a deploy.
  #   * a rescue. The sync needs Sidekiq and CouchDB, and neither is guaranteed
  #     to be up while migrations run; a refresh that cannot start must not fail
  #     a relabel that already committed. (MySQL runs migrations outside a
  #     transaction, so the UPDATE above is durable before we get here and the
  #     workers cannot read pre-relabel rows.)
  #   * calling it only when something was actually relabelled. This rebuilds
  #     every patient document and resets sync progress, so an environment with
  #     nothing to fix should not pay for it.
  #
  # Note the task returns quietly, without raising, when CouchDB is unreachable
  # -- it prints its own "CouchDB is unreachable" line, which is the signal to
  # re-run the sync by hand.
  def trigger_patient_document_rebuild(patient_ids)
    previous_watch = ENV['WATCH']
    watch_was_set = ENV.key?('WATCH')

    require 'rake'
    Rails.application.load_tasks unless Rake::Task.task_defined?(REBUILD_TASK)

    say("Rebuilding CouchDB patient documents so #{patient_ids.inspect} pick up the new " \
        'label. This rebuilds every eligible patient document and resets sync progress.', true)

    ENV['WATCH'] = '0'
    Rake::Task[REBUILD_TASK].reenable
    Rake::Task[REBUILD_TASK].invoke(REBUILD_TASK_ARGUMENT)
  rescue StandardError => e
    say("Could not start the CouchDB rebuild (#{e.class}: #{e.message}). The relabel is " \
        "committed; run #{manual_rebuild_command} once CouchDB and Sidekiq are up.", true)
  ensure
    watch_was_set ? ENV['WATCH'] = previous_watch : ENV.delete('WATCH')
  end

  def manual_rebuild_command
    %(rails "#{REBUILD_TASK}[#{REBUILD_TASK_ARGUMENT}]")
  end

  def required_tables_present?
    REQUIRED_TABLES.all? { |table| table_exists?(table) }
  end

  def mislabelled_relationship_type_id
    select_value(<<~SQL.squish)
      SELECT relationship_type_id FROM relationship_type
      WHERE relationship_type_id = #{MISLABELLED_TYPE_ID}
        AND a_is_to_b = #{quote(MISLABELLED_A_IS_TO_B)}
        AND b_is_to_a = #{quote(MISLABELLED_B_IS_TO_A)}
      LIMIT 1
    SQL
  end

  def correct_relationship_type_id
    select_value(<<~SQL.squish)
      SELECT relationship_type_id FROM relationship_type
      WHERE a_is_to_b = #{quote(CORRECT_A_IS_TO_B)}
        AND b_is_to_a = #{quote(CORRECT_B_IS_TO_A)}
        AND retired = 0
      ORDER BY relationship_type_id
      LIMIT 1
    SQL
  end

  def mother_baby_rows(mislabelled_type_id)
    select_all(<<~SQL.squish).to_a
      SELECT r.relationship_id, r.person_a, r.person_b, DATE(r.date_created) AS date_created, baby.birthdate
      FROM relationship r
      JOIN person baby ON baby.person_id = r.person_b
      JOIN patient baby_patient ON baby_patient.patient_id = r.person_b AND baby_patient.voided = 0
      WHERE r.voided = 0
        AND r.relationship = #{mislabelled_type_id}
        AND #{delivery_link_conditions}
      ORDER BY r.relationship_id
    SQL
  end

  def declined_rows(mislabelled_type_id)
    select_all(<<~SQL.squish).to_a
      SELECT r.relationship_id, r.person_a, r.person_b, DATE(r.date_created) AS date_created, baby.birthdate
      FROM relationship r
      JOIN person baby ON baby.person_id = r.person_b
      JOIN patient baby_patient ON baby_patient.patient_id = r.person_b AND baby_patient.voided = 0
      WHERE r.voided = 0
        AND r.relationship = #{mislabelled_type_id}
        AND NOT (#{delivery_link_conditions})
      ORDER BY r.relationship_id
    SQL
  end

  def delivery_link_conditions
    <<~SQL.squish
      baby.birthdate IS NOT NULL
      AND DATEDIFF(r.date_created, baby.birthdate) BETWEEN 0 AND #{MAX_BABY_AGE_DAYS}
      AND EXISTS (
        SELECT 1 FROM patient_program pp
        JOIN program pg ON pg.program_id = pp.program_id
        WHERE pp.patient_id = r.person_a
          AND pp.voided = 0
          AND pg.name IN (#{DELIVERY_PROGRAM_NAMES.map { |name| quote(name) }.join(',')})
      )
    SQL
  end

  def select_value(sql)
    connection.select_value(sql)
  end

  def select_all(sql)
    connection.select_all(sql)
  end

  def quote(value)
    connection.quote(value)
  end
end
