# frozen_string_literal: true

require_relative 'tidb_support'

module TidbReporting
  REPLICA_TABLES = %w[
    concept_name
    concept_set
    drug
    drug_order
    encounter
    obs
    orders
    patient
    patient_program
    patient_state
    person
    person_address
    person_name
    relationship
    reporting_patient_art_facts
  ].freeze

  module_function

  def with_analytics_session(connection = ActiveRecord::Base.connection, materialize: false)
    return yield(connection) unless TidbSupport.enabled?(connection)

    previous_values = desired_session_variables(connection, materialize:).to_h do |name, value|
      [name, [session_value(connection, name), value]]
    end

    previous_values.each { |name, (_previous, value)| set_session_value(connection, name, value) }
    yield(connection)
  ensure
    previous_values&.each do |name, (previous, _value)|
      set_session_value(connection, name, previous) unless previous.nil?
    end
  end

  def tiflash_replicas(connection = ActiveRecord::Base.connection)
    connection.select_all(<<~SQL).to_a
      SELECT TABLE_NAME, REPLICA_COUNT, AVAILABLE, PROGRESS
      FROM information_schema.TIFLASH_REPLICA
      WHERE TABLE_SCHEMA = DATABASE()
      ORDER BY TABLE_NAME
    SQL
  end

  def available_replica?(table_name, connection = ActiveRecord::Base.connection)
    tiflash_replicas(connection).any? do |replica|
      replica['TABLE_NAME'] == table_name.to_s && replica['AVAILABLE'].to_i == 1
    end
  end

  def desired_session_variables(connection = ActiveRecord::Base.connection, materialize: false)
    enforce_mpp = ENV.fetch('TIDB_REPORTING_ENFORCE_MPP', materialize ? 'true' : 'false')
    variables = {
      'tidb_allow_mpp' => 1,
      'tidb_enforce_mpp' => truthy?(enforce_mpp) ? 1 : 0
    }

    return variables unless materialize

    sql_mode = session_value(connection, 'sql_mode').to_s.split(',')
    sql_mode -= %w[STRICT_TRANS_TABLES STRICT_ALL_TABLES]
    variables.merge(
      'tidb_enable_tiflash_read_for_write_stmt' => 1,
      'sql_mode' => sql_mode.join(',')
    )
  end

  def truthy?(value)
    %w[1 true yes on].include?(value.to_s.downcase)
  end
  private_class_method :truthy?

  def session_value(connection, name)
    connection.select_value("SELECT @@SESSION.#{name}")
  rescue ActiveRecord::StatementInvalid
    nil
  end
  private_class_method :session_value

  def set_session_value(connection, name, value)
    connection.execute("SET SESSION #{name} = #{connection.quote(value)}")
  end
  private_class_method :set_session_value
end
