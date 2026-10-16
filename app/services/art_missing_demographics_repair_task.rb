# frozen_string_literal: true

# Restores missing ART patient demographics from the untouched pre-migration
# database. Matching requires both the person UUID and an active ARV number.
class ArtMissingDemographicsRepairTask
  CONFIRMATION = 'RESTORE_MISSING_ART_DEMOGRAPHICS_FROM_SOURCE'
  SOURCE_DATABASE = 'mahis_dup'
  TARGET_DATABASE = 'mahis_prod'
  PROGRAM_ID = 1
  ARV_IDENTIFIER_TYPE = 4
  VALID_GENDERS = %w[M MALE F FEMALE].freeze
  TRUTHY = %w[1 true yes y].freeze

  def initialize(env = ENV, connection: ActiveRecord::Base.connection)
    @connection = connection
    @apply = truthy?(env['APPLY'])
    @approve_all = truthy?(env['APPROVE_ALL'])
    @source_database = env.fetch('SOURCE_DB', SOURCE_DATABASE).to_s
    @target_database = env.fetch('TARGET_DB', TARGET_DATABASE).to_s
    @operator_user_id = env['USER_ID'].to_i
    @confirmation = env['CONFIRM'].to_s
    validate_options!
  end

  def run
    validate_databases!
    rows = candidates

    puts "\n===== Missing ART Demographics Repair ====="
    puts "Source database: #{@source_database}"
    puts "Target database: #{@target_database}"
    puts "Patients eligible for repair: #{rows.length}"
    rows.each do |row|
      puts "  patient_id=#{row['target_id']} uuid=#{row['uuid']} ARV=#{row['arv_number']} " \
           "gender=#{row['target_gender'].inspect}->#{row['source_gender'].inspect} " \
           "birthdate=#{row['target_birthdate'].inspect}->#{row['source_birthdate']}"
    end

    unless @apply
      puts 'No records changed.'
      puts "Apply with: APPLY=1 APPROVE_ALL=1 CONFIRM=#{CONFIRMATION} USER_ID=<id> " \
           'bin/rails patients:repair_missing_art_demographics'
      return
    end

    @connection.transaction do
      rows.each { |row| repair!(row) }
    end
    puts "Restored demographics for #{rows.length} patient(s)."
  end

  private

  def validate_options!
    [@source_database, @target_database].each do |database|
      unless database.match?(/\A[A-Za-z0-9_]+\z/)
        raise ArgumentError, 'Database names may contain only letters, numbers, and underscores'
      end
    end
    raise ArgumentError, 'SOURCE_DB and TARGET_DB must differ' if @source_database.casecmp?(@target_database)
    return unless @apply

    raise ArgumentError, 'APPROVE_ALL=1 is required' unless @approve_all
    raise ArgumentError, "CONFIRM=#{CONFIRMATION} is required" unless @confirmation == CONFIRMATION
    raise ArgumentError, 'USER_ID must identify the operator' unless @operator_user_id.positive?
  end

  def validate_databases!
    available = select_all('SELECT SCHEMA_NAME FROM information_schema.SCHEMATA')
                .map { |row| row['SCHEMA_NAME'].downcase }
    [@source_database, @target_database].each do |database|
      raise "Database #{database.inspect} is unavailable" unless available.include?(database.downcase)
    end

    @connection.execute("USE #{quote_table(@target_database)}")
    current = @connection.select_value('SELECT DATABASE()').to_s
    raise "Connected database is #{current.inspect}; expected #{@target_database.inspect}" unless current.casecmp?(@target_database)

    return unless @apply
    return if @connection.select_value("SELECT 1 FROM users WHERE user_id=#{@operator_user_id} LIMIT 1")

    raise "User #{@operator_user_id} does not exist in #{@target_database}"
  end

  def candidates
    select_all(<<~SQL)
      SELECT DISTINCT
        target.person_id AS target_id,
        target.uuid,
        target.gender AS target_gender,
        target.birthdate AS target_birthdate,
        target.birthdate_estimated AS target_birthdate_estimated,
        source.person_id AS source_id,
        source.gender AS source_gender,
        source.birthdate AS source_birthdate,
        source.birthdate_estimated AS source_birthdate_estimated,
        target_arv.identifier AS arv_number
      FROM #{quote_table(@target_database)}.person target
      INNER JOIN #{quote_table(@source_database)}.person source
        ON source.uuid=target.uuid AND source.voided=0
      INNER JOIN #{quote_table(@target_database)}.patient_program target_program
        ON target_program.patient_id=target.person_id
       AND target_program.program_id=#{PROGRAM_ID} AND target_program.voided=0
      INNER JOIN #{quote_table(@source_database)}.patient_program source_program
        ON source_program.patient_id=source.person_id
       AND source_program.program_id=#{PROGRAM_ID} AND source_program.voided=0
      INNER JOIN #{quote_table(@target_database)}.patient_identifier target_arv
        ON target_arv.patient_id=target.person_id
       AND target_arv.identifier_type=#{ARV_IDENTIFIER_TYPE} AND target_arv.voided=0
       AND NULLIF(TRIM(target_arv.identifier), '') IS NOT NULL
      INNER JOIN #{quote_table(@source_database)}.patient_identifier source_arv
        ON source_arv.patient_id=source.person_id
       AND source_arv.identifier_type=#{ARV_IDENTIFIER_TYPE} AND source_arv.voided=0
       AND source_arv.identifier=target_arv.identifier
      WHERE target.voided=0
        AND (
          (UPPER(TRIM(COALESCE(target.gender, ''))) NOT IN ('M', 'MALE', 'F', 'FEMALE')
           AND UPPER(TRIM(source.gender)) IN ('M', 'MALE', 'F', 'FEMALE'))
          OR (target.birthdate IS NULL AND source.birthdate IS NOT NULL)
        )
      ORDER BY target.person_id
    SQL
  end

  def repair!(row)
    current = select_all(<<~SQL).first
      SELECT person_id, uuid, gender, birthdate, birthdate_estimated
      FROM #{quote_table(@target_database)}.person
      WHERE person_id=#{row['target_id'].to_i} AND uuid=#{quote(row['uuid'])} AND voided=0
      LIMIT 1
      FOR UPDATE
    SQL
    raise "Target patient #{row['uuid']} changed after review" unless current

    updates = {}
    if !valid_gender?(current['gender']) && valid_gender?(row['source_gender'])
      updates['gender'] = row['source_gender']
    end
    if current['birthdate'].blank? && row['source_birthdate'].present?
      updates['birthdate'] = row['source_birthdate']
      updates['birthdate_estimated'] = row['source_birthdate_estimated']
    end
    return if updates.empty?

    updates['changed_by'] = @operator_user_id
    updates['date_changed'] = Time.current
    assignments = updates.map { |column, value| "#{quote_column(column)}=#{quote(value)}" }.join(', ')
    affected = @connection.update(<<~SQL)
      UPDATE #{quote_table(@target_database)}.person
      SET #{assignments}
      WHERE person_id=#{row['target_id'].to_i} AND uuid=#{quote(row['uuid'])} AND voided=0
        AND gender <=> #{quote(current['gender'])}
        AND birthdate <=> #{quote(current['birthdate'])}
        AND birthdate_estimated <=> #{quote(current['birthdate_estimated'])}
    SQL
    raise "Failed to update target patient #{row['uuid']}" unless affected == 1
  end

  def select_all(sql)
    @connection.select_all(sql).to_a
  end

  def quote(value)
    @connection.quote(value)
  end

  def quote_table(value)
    @connection.quote_table_name(value)
  end

  def quote_column(value)
    @connection.quote_column_name(value)
  end

  def truthy?(value)
    TRUTHY.include?(value.to_s.downcase)
  end

  def valid_gender?(value)
    VALID_GENDERS.include?(value.to_s.strip.upcase)
  end
end
