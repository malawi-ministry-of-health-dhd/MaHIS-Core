# frozen_string_literal: true

# This is a module that can be included in any class that needs to use the methods defined here.
# but essentially this will prepare all temp tables requires in the system

module ArtTempTablesUtils
  include ArtTempTablesNaming

  def prepare_tables(skip_shared: false, force_rebuild: false)
    already_built = !force_rebuild && outcome_tables_populated?
    prepare_cohort_tables(skip_shared: skip_shared, force_rebuild: force_rebuild)
    # Skip outcome/maternal DDL entirely when data is already present and we're not forcing a rebuild
    prepare_outcome_tables(force_rebuild: force_rebuild) unless already_built
    prepare_maternal_tables(force_rebuild: force_rebuild) unless already_built
  end

  # rubocop:disable Metrics/MethodLength
  # rubocop:disable Metrics/AbcSize
  # rubocop:disable Metrics/PerceivedComplexity
  # rubocop:disable Metrics/CyclomaticComplexity
  def prepare_cohort_tables(skip_shared: false, force_rebuild: false)
    if force_rebuild
      # Drop all cohort tables then immediately recreate empty — clean slate for full rebuild
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_cohort_members}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_earliest_start_date}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_other_patient_types}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_register_start_date}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_order_details}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_art_start_date}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_patient_tb_status}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_latest_tb_status}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{tmp_max_adherence}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_pregnant_obs}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_patient_side_effects}")
      create_temp_cohort_members_table
      create_tmp_patient_table
      create_temp_other_patient_types
      create_temp_register_start_date_table
      create_temp_order_details
      create_art_start_date
      create_temp_patient_tb_status
      create_temp_latest_tb_status
      create_tmp_max_adherence
      create_temp_pregnant_obs
      create_temp_patient_side_effects
      return
    end

    # When skip_shared is true the tables already have valid populated data — reuse as-is
    return if skip_shared

    cols = batch_column_counts(
      temp_cohort_members, temp_earliest_start_date, temp_other_patient_types,
      temp_register_start_date, temp_order_details, temp_art_start_date,
      temp_patient_tb_status, temp_latest_tb_status, tmp_max_adherence,
      temp_pregnant_obs, temp_patient_side_effects
    )

    if cols[temp_cohort_members] == 0
      create_temp_cohort_members_table
    else
      (drop_temp_cohort_members_table unless cols[temp_cohort_members] == 12)
    end
    if cols[temp_earliest_start_date] == 0
      create_tmp_patient_table
    else
      (drop_tmp_patient_table unless cols[temp_earliest_start_date] == 11)
    end
    if cols[temp_other_patient_types] == 0
      create_temp_other_patient_types
    else
      (drop_temp_other_patient_types unless cols[temp_other_patient_types] == 1)
    end
    if cols[temp_register_start_date] == 0
      create_temp_register_start_date_table
    else
      (drop_temp_register_start_date_table unless cols[temp_register_start_date] == 2)
    end
    if cols[temp_order_details] == 0
      create_temp_order_details
    else
      (drop_temp_order_details unless cols[temp_order_details] == 2)
    end
    if cols[temp_art_start_date] == 0
      create_art_start_date
    else
      (drop_art_start_date unless cols[temp_art_start_date] == 2)
    end
    if cols[temp_patient_tb_status] == 0
      create_temp_patient_tb_status
    else
      (drop_temp_patient_tb_status unless cols[temp_patient_tb_status] == 2)
    end
    if cols[temp_latest_tb_status] == 0
      create_temp_latest_tb_status
    else
      (drop_temp_latest_tb_status unless cols[temp_latest_tb_status] == 2)
    end
    if cols[tmp_max_adherence] == 0
      create_tmp_max_adherence
    else
      (drop_tmp_max_adherence unless cols[tmp_max_adherence] == 2)
    end
    if cols[temp_pregnant_obs] == 0
      create_temp_pregnant_obs
    else
      (drop_temp_pregnant_obs unless cols[temp_pregnant_obs] == 3)
    end
    if cols[temp_patient_side_effects] == 0
      create_temp_patient_side_effects
    else
      (drop_temp_patient_side_effects unless cols[temp_patient_side_effects] == 2)
    end

    truncate_cohort_tables
  end

  def prepare_outcome_tables(force_rebuild: false)
    [false, true].each do |start|
      if force_rebuild
        # Drop and immediately recreate empty so Cohort::Outcomes can truncate and repopulate
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_patient_outcomes(start: start)}")
        create_outcome_table(start:)
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_max_drug_orders(start: start)}")
        create_temp_max_drug_orders_table(start:)
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_min_auto_expire_date(start: start)}")
        create_tmp_min_auto_expire_date(start:)
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_max_patient_state(start: start)}")
        create_temp_max_patient_state(start:)
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_current_state(start: start)}")
        create_temp_current_state(start:)
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_current_medication(start: start)}")
        create_temp_current_medication(start:)
        next
      end

      table_names = [
        temp_patient_outcomes(start:), temp_max_drug_orders(start:),
        temp_min_auto_expire_date(start:), temp_max_patient_state(start:),
        temp_current_state(start:), temp_current_medication(start:)
      ]
      cols = batch_column_counts(*table_names)

      if cols[temp_patient_outcomes(start:)] == 0
        create_outcome_table(start:)
      else
        (drop_temp_patient_outcome_table(start:) unless cols[temp_patient_outcomes(start:)] == 6)
      end
      if cols[temp_max_drug_orders(start:)] == 0
        create_temp_max_drug_orders_table(start:)
      else
        (drop_temp_max_drug_orders_table(start:) unless cols[temp_max_drug_orders(start:)] == 3)
      end
      if cols[temp_min_auto_expire_date(start:)] == 0
        create_tmp_min_auto_expire_date(start:)
      else
        (drop_tmp_min_auto_expirte_date(start:) unless cols[temp_min_auto_expire_date(start:)] == 5)
      end
      create_temp_max_patient_state(start:) if cols[temp_max_patient_state(start:)] == 0
      # Use if/elsif so we never drop a table we just created in this same snapshot
      if cols[temp_current_state(start:)]      == 0
        create_temp_current_state(start:)
      elsif cols[temp_current_state(start:)]   != 6
        drop_temp_current_state(start:)
      end
      create_temp_current_medication(start:) if cols[temp_current_medication(start:)] == 0
    end
  end

  def prepare_maternal_tables(force_rebuild: false)
    if force_rebuild
      # Drop and immediately recreate empty so MaternalStatus can repopulate
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_maternal_status}")
      create_temp_maternal_status
      return
    end

    cols = batch_column_counts(temp_maternal_status)
    if cols[temp_maternal_status] == 0
      create_temp_maternal_status
    elsif cols[temp_maternal_status] != 2
      drop_temp_maternal_status
    end
  end

  # rubocop:enable Metrics/AbcSize
  # rubocop:enable Metrics/PerceivedComplexity
  # rubocop:enable Metrics/CyclomaticComplexity

  private

  # Single INFORMATION_SCHEMA query for multiple tables. Returns { table_name => column_count }.
  # Tables that do not exist have a count of 0.
  def batch_column_counts(*table_names)
    quoted = table_names.map { |t| ActiveRecord::Base.connection.quote(t) }.join(', ')
    rows = ActiveRecord::Base.connection.select_all <<~SQL
      SELECT table_name, COUNT(*) AS col_count
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE table_schema = DATABASE()
      AND table_name IN (#{quoted})
      GROUP BY table_name
    SQL
    result = table_names.each_with_object({}) { |t, h| h[t] = 0 }
    rows.each { |row| result[row['table_name']] = row['col_count'].to_i }
    result
  end

  # Executes a CREATE INDEX / ALTER TABLE ADD INDEX statement, silently
  # ignoring duplicate-key errors that arise when the table already has the index
  # (e.g. CREATE TABLE IF NOT EXISTS + separate CREATE INDEX race condition).
  def safe_create_index(sql)
    ActiveRecord::Base.connection.execute(sql)
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.message.include?('Duplicate key name')
  end

  def shared_cohort_tables_populated?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM #{temp_earliest_start_date}"
    ).to_i.positive?
  rescue ActiveRecord::StatementInvalid
    false
  end

  def outcome_tables_populated?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM #{temp_patient_outcomes}"
    ).to_i.positive?
  rescue ActiveRecord::StatementInvalid
    false
  end

  def check_if_table_exists(table_name)
    result = ActiveRecord::Base.connection.select_one <<~SQL
      SELECT COUNT(*) AS count
      FROM information_schema.tables
      WHERE table_schema = DATABASE()
      AND table_name = '#{table_name}'
    SQL
    result['count'].to_i.positive?
  end

  def count_table_columns(table_name)
    result = ActiveRecord::Base.connection.select_one <<~SQL
      SELECT COUNT(*) AS count
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE table_schema = DATABASE()
      AND table_name = '#{table_name}'
    SQL
    result['count'].to_i
  end

  # ===================================
  #  Cohort Table Management Region
  # ===================================

  def drop_temp_cohort_members_table
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_cohort_members}")
    create_temp_cohort_members_table
  end

  def create_temp_cohort_members_table
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_cohort_members} (
        patient_id INT PRIMARY KEY,
        date_enrolled DATE,
        earliest_start_date DATE,
        recorded_start_date DATE DEFAULT NULL,
        birthdate DATE DEFAULT NULL,
        birthdate_estimated BOOLEAN,
        death_date DATE,
        gender VARCHAR(32),
        age_at_initiation INT DEFAULT NULL,
        age_in_days INT DEFAULT NULL,
        reason_for_starting_art INT DEFAULT NULL,
        occupation VARCHAR(255) DEFAULT NULL
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8;
    SQL
    create_temp_cohort_members_index
  end

  def create_temp_cohort_members_index
    safe_create_index("CREATE INDEX #{temp_index_name('member_id_index')} ON #{temp_cohort_members} (patient_id)")
    safe_create_index("CREATE INDEX #{temp_index_name('member_enrolled_index')} ON #{temp_cohort_members} (date_enrolled)")
    safe_create_index("CREATE INDEX #{temp_index_name('member_date_enrolled_index')} ON #{temp_cohort_members} (patient_id, date_enrolled)")
    safe_create_index("CREATE INDEX #{temp_index_name('member_start_date_index')} ON #{temp_cohort_members} (earliest_start_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('member_start_date__date_enrolled_index')} ON #{temp_cohort_members} (patient_id, earliest_start_date, date_enrolled, gender)")
    safe_create_index("CREATE INDEX #{temp_index_name('member_reason')} ON #{temp_cohort_members} (reason_for_starting_art)")
    safe_create_index("CREATE INDEX #{temp_index_name('member_birthdate_idx')} ON #{temp_cohort_members} (birthdate)")
    safe_create_index("CREATE INDEX #{temp_index_name('member_occupation_idx')} ON #{temp_cohort_members} (birthdate)")
  end

  def drop_tmp_patient_table
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_earliest_start_date}")
    create_tmp_patient_table
  end

  def create_tmp_patient_table
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_earliest_start_date} (
         patient_id INT PRIMARY KEY,
         date_enrolled DATE,
         earliest_start_date DATE,
         recorded_start_date DATE DEFAULT NULL,
         birthdate DATE DEFAULT NULL,
         birthdate_estimated BOOLEAN,
         death_date DATE,
         gender VARCHAR(32),
         age_at_initiation INT DEFAULT NULL,
         age_in_days INT DEFAULT NULL,
         reason_for_starting_art INT DEFAULT NULL
      )
    SQL
    create_tmp_patient_table_indexes
  end

  def create_tmp_patient_table_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('patient_id_index')} ON #{temp_earliest_start_date} (patient_id)")
    safe_create_index("CREATE INDEX #{temp_index_name('date_enrolled_index')} ON #{temp_earliest_start_date} (date_enrolled)")
    safe_create_index("CREATE INDEX #{temp_index_name('patient_id__date_enrolled_index')} ON #{temp_earliest_start_date} (patient_id, date_enrolled)")
    safe_create_index("CREATE INDEX #{temp_index_name('earliest_start_date_index')} ON #{temp_earliest_start_date} (earliest_start_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('earliest_start_date__date_enrolled_index')} ON #{temp_earliest_start_date} (patient_id, earliest_start_date, date_enrolled, gender)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_reason_for_art')} ON #{temp_earliest_start_date} (reason_for_starting_art)")
    safe_create_index("CREATE INDEX #{temp_index_name('birthdate_idx')} ON #{temp_earliest_start_date} (birthdate)")
  end

  def drop_temp_register_start_date_table
    ActiveRecord::Base.connection.execute <<-SQL
      DROP TABLE IF EXISTS #{temp_register_start_date}
    SQL
    create_temp_register_start_date_table
  end

  def create_temp_register_start_date_table
    ActiveRecord::Base.connection.execute <<-SQL
      CREATE TABLE IF NOT EXISTS #{temp_register_start_date} (
        patient_id INT(11) NOT NULL,
        start_date DATE NOT NULL,
        PRIMARY KEY (patient_id)
      )
    SQL
    create_temp_register_start_date_table_indexes
  end

  def create_temp_register_start_date_table_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('trsd_date')} ON #{temp_register_start_date} (start_date)")
  end

  def drop_temp_other_patient_types
    ActiveRecord::Base.connection.execute <<~SQL
      DROP TABLE IF EXISTS #{temp_other_patient_types}
    SQL
    create_temp_other_patient_types
  end

  def create_temp_other_patient_types
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_other_patient_types} (
        patient_id INT(11) NOT NULL,
        PRIMARY KEY (patient_id)
      )
    SQL
  end

  def drop_temp_order_details
    ActiveRecord::Base.connection.execute <<~SQL
      DROP TABLE IF EXISTS #{temp_order_details}
    SQL
    create_temp_order_details
  end

  def create_temp_order_details
    ActiveRecord::Base.connection.execute <<-SQL
      CREATE TABLE IF NOT EXISTS #{temp_order_details} (
        patient_id INT NOT NULL,
        start_date DATE NOT NULL,
        PRIMARY KEY (patient_id)
      )
    SQL
    create_temp_order_details_indexes
  end

  def create_temp_order_details_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('tod_date')} ON #{temp_order_details} (start_date)")
  end

  def drop_art_start_date
    ActiveRecord::Base.connection.execute <<~SQL
      DROP TABLE IF EXISTS #{temp_art_start_date}
    SQL
    create_art_start_date
  end

  def create_art_start_date
    ActiveRecord::Base.connection.execute <<-SQL
      CREATE TABLE IF NOT EXISTS #{temp_art_start_date} (
        patient_id INT(11) NOT NULL,
        value_datetime DATE NOT NULL,
        PRIMARY KEY (patient_id)
      )
    SQL
    create_art_start_date_indexes
  end

  def create_art_start_date_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('tasd_date')} ON #{temp_art_start_date} (value_datetime)")
  end

  def drop_temp_patient_tb_status
    ActiveRecord::Base.connection.execute(
      "DROP TABLE IF EXISTS #{temp_patient_tb_status}"
    )
    create_temp_patient_tb_status
  end

  def create_temp_patient_tb_status
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_patient_tb_status} (
        patient_id INT(11) PRIMARY KEY,
        tb_status INT(11)
      )
    SQL
    create_temp_patient_tb_status_indexes
  end

  def create_temp_patient_tb_status_indexes
    safe_create_index("ALTER TABLE #{temp_patient_tb_status} ADD INDEX #{temp_index_name('patient_id_index')} (patient_id)")
    safe_create_index("ALTER TABLE #{temp_patient_tb_status} ADD INDEX #{temp_index_name('tb_status_index')} (tb_status)")
    safe_create_index("ALTER TABLE #{temp_patient_tb_status} ADD INDEX #{temp_index_name('patient_id_tb_status_index')} (patient_id, tb_status)")
  end

  def drop_temp_latest_tb_status
    ActiveRecord::Base.connection.execute(
      "DROP TABLE IF EXISTS #{temp_latest_tb_status}"
    )
    create_temp_latest_tb_status
  end

  def create_temp_latest_tb_status
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_latest_tb_status}(
        person_id INT PRIMARY KEY,
        obs_datetime DATETIME
      )
    SQL
  end

  def create_temp_latest_tb_status_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('tlts_date')} ON #{temp_latest_tb_status}(obs_datetime)")
  end

  def drop_tmp_max_adherence
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{tmp_max_adherence}")
    create_tmp_max_adherence
  end

  def create_tmp_max_adherence
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{tmp_max_adherence} (
        person_id INT PRIMARY KEY,
        visit_date DATE
      )
    SQL
    create_tmp_max_adherence_indexes
  end

  def create_tmp_max_adherence_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('tma_date')} ON #{tmp_max_adherence} (visit_date)")
  end

  def drop_temp_pregnant_obs
    ActiveRecord::Base.connection.execute "DROP TABLE IF EXISTS #{temp_pregnant_obs}"
    create_temp_pregnant_obs
  end

  def create_temp_pregnant_obs
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_pregnant_obs}(
        person_id INT PRIMARY KEY,
        value_coded INT  NULL,
        obs_datetime DATE NULL
      )
    SQL
    create_temp_pregnant_obs_indexes
  end

  def create_temp_pregnant_obs_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('fre_obs_time')} ON #{temp_pregnant_obs}(obs_datetime)")
  end

  def drop_temp_patient_side_effects
    ActiveRecord::Base.connection.execute <<~SQL
      DROP TABLE IF EXISTS #{temp_patient_side_effects}
    SQL
    create_temp_patient_side_effects
  end

  def create_temp_patient_side_effects
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_patient_side_effects} (
        patient_id INT(11) PRIMARY KEY,
        has_se VARCHAR(120) NOT NULL
      )
    SQL
    create_temp_patient_side_effects_indexes
  end

  def create_temp_patient_side_effects_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('idx_side_effects')} ON #{temp_patient_side_effects} (patient_id, has_se)")
  end

  # ===================================
  # Maternal Status Table Management Region
  # ===================================

  def drop_temp_maternal_status
    ActiveRecord::Base.connection.execute "DROP TABLE IF EXISTS #{temp_maternal_status}"
    create_temp_maternal_status
  end

  def create_temp_maternal_status
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_maternal_status} (
        patient_id INT PRIMARY KEY,
        maternal_status VARCHAR(5) NOT NULL
      )
    SQL
    create_temp_maternal_status_indexes
  end

  def create_temp_maternal_status_indexes
    safe_create_index("CREATE INDEX #{temp_index_name('idx_maternal_status')} ON #{temp_maternal_status} (patient_id, maternal_status)")
  end

  # ===================================
  #  Outcome Table Management Region
  # ===================================

  def create_temp_current_medication(start: false)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_current_medication(start: start)}(
        patient_id INT NOT NULL,
        concept_id INT NOT NULL,
        drug_id INT NOT NULL,
        daily_dose DECIMAL(32,2) NOT NULL,
        quantity DECIMAL(32,2) NOT NULL,
        start_date DATE NOT NULL,
        pill_count DECIMAL(32,2) NULL,
        expiry_date DATE NULL,
        pepfar_defaulter_date DATE NULL,
        moh_defaulter_date DATE NULL,
        PRIMARY KEY(patient_id, drug_id)
      )
    SQL
    craete_tmp_current_med_index(start:)
  end

  def craete_tmp_current_med_index(start: false)
    safe_create_index("CREATE INDEX #{temp_index_name('idx_cm_concept',
                                                      start: start)} ON #{temp_current_medication(start: start)} (concept_id)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_cm_drug',
                                                      start: start)} ON #{temp_current_medication(start: start)} (drug_id)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_cm_date',
                                                      start: start)} ON #{temp_current_medication(start: start)} (start_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_cm_pepfar',
                                                      start: start)} ON #{temp_current_medication(start: start)} (pepfar_defaulter_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_cm_moh',
                                                      start: start)} ON #{temp_current_medication(start: start)} (moh_defaulter_date)")
  end

  def create_temp_current_state(start: false)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_current_state(start: start)}(
        patient_id INT NOT NULL,
        cum_outcome VARCHAR(120) NOT NULL,
        outcome_date DATE DEFAULT NULL,
        state INT NOT NULL,
        outcomes INT NOT NULL,
        patient_state_id INT NOT NULL,
        PRIMARY KEY(patient_id))
    SQL
    create_current_state_index(start:)
  end

  def create_current_state_index(start: false)
    safe_create_index("CREATE INDEX #{temp_index_name('idx_state_name',
                                                      start: start)} ON #{temp_current_state(start: start)} (cum_outcome)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_state_id',
                                                      start: start)} ON #{temp_current_state(start: start)} (state)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_state_count',
                                                      start: start)} ON #{temp_current_state(start: start)} (outcomes)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_patient_state_id',
                                                      start: start)} ON #{temp_current_state(start: start)} (patient_state_id)")
  end

  def create_tmp_min_auto_expire_date(start: false)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_min_auto_expire_date(start: start)} (
        patient_id INT NOT NULL,
        start_date DATE DEFAULT NULL,
        auto_expire_date DATE DEFAULT NULL,
        pepfar_defaulter_date DATE DEFAULT NULL,
        moh_defaulter_date DATE DEFAULT NULL,
        PRIMARY KEY (patient_id)
      )
    SQL
    create_min_auto_expire_date_indexes(start:)
  end
  # rubocop:enable Metrics/MethodLength

  def drop_temp_current_state(start: false)
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_current_state(start: start)}")
    create_temp_current_state(start:)
  end

  def drop_temp_patient_outcome_table(start: false)
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_patient_outcomes(start: start)}")
    create_outcome_table(start:)
  end

  def create_outcome_table(start: false)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_patient_outcomes(start: start)} (
      patient_id INT NOT NULL,
      moh_cum_outcome VARCHAR(120) NOT NULL,
      moh_outcome_date DATE DEFAULT NULL,
      pepfar_cum_outcome VARCHAR(120) NOT NULL,
      pepfar_outcome_date DATE DEFAULT NULL,
      step INT DEFAULT 0,
      PRIMARY KEY (patient_id)
      )
    SQL
    create_outcome_indexes(start:)
  end

  def create_outcome_indexes(start: false)
    safe_create_index("CREATE INDEX #{temp_index_name('moh_outcome',
                                                      start: start)} ON #{temp_patient_outcomes(start: start)} (moh_cum_outcome)")
    safe_create_index("CREATE INDEX #{temp_index_name('moh_out_date',
                                                      start: start)} ON #{temp_patient_outcomes(start: start)} (moh_outcome_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('pepfar_outcome',
                                                      start: start)} ON #{temp_patient_outcomes(start: start)} (pepfar_cum_outcome)")
    safe_create_index("CREATE INDEX #{temp_index_name('pepfar_out_date',
                                                      start: start)} ON #{temp_patient_outcomes(start: start)} (pepfar_outcome_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_out_step',
                                                      start: start)} ON #{temp_patient_outcomes(start: start)} (step)")
  end

  def drop_temp_max_drug_orders_table(start: false)
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_max_drug_orders(start: start)}")
    create_temp_max_drug_orders_table(start:)
  end

  def create_temp_max_drug_orders_table(start: false)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_max_drug_orders(start: start)} (
        patient_id INT NOT NULL,
        start_date DATETIME DEFAULT NULL,
        min_order_date DATETIME DEFAULT NULL,
        PRIMARY KEY (patient_id)
      )
    SQL
    create_max_drug_orders_indexes(start:)
  end

  def create_max_drug_orders_indexes(start: false)
    safe_create_index("CREATE INDEX #{temp_index_name('idx_max_orders',
                                                      start: start)} ON #{temp_max_drug_orders(start: start)} (start_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_max_min_orders',
                                                      start: start)} ON #{temp_max_drug_orders(start: start)} (min_order_date)")
  end

  def drop_tmp_min_auto_expirte_date(start: false)
    ActiveRecord::Base.connection.execute "DROP TABLE IF EXISTS #{temp_min_auto_expire_date(start: start)}"
    create_tmp_min_auto_expire_date(start:)
  end

  def create_min_auto_expire_date_indexes(start: false)
    safe_create_index("CREATE INDEX #{temp_index_name('idx_min_auto_expire_date',
                                                      start: start)} ON #{temp_min_auto_expire_date(start: start)} (auto_expire_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_min_pepfar',
                                                      start: start)} ON #{temp_min_auto_expire_date(start: start)} (pepfar_defaulter_date)")
    safe_create_index("CREATE INDEX #{temp_index_name('idx_min_moh',
                                                      start: start)} ON #{temp_min_auto_expire_date(start: start)} (moh_defaulter_date)")
  end

  def create_temp_max_patient_state(start: false)
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TABLE IF NOT EXISTS #{temp_max_patient_state(start: start)} (
        patient_id INT NOT NULL,
        start_date VARCHAR(15) DEFAULT NULL,
        PRIMARY KEY (patient_id)
      )
    SQL
    create_max_patient_state_indexes(start:)
  end

  def create_max_patient_state_indexes(start: false)
    safe_create_index("CREATE INDEX #{temp_index_name('idx_max_patient_state',
                                                      start: start)} ON #{temp_max_patient_state(start: start)} (start_date)")
  end

  def update_steps(start: false, portion: false)
    ActiveRecord::Base.connection.execute <<~SQL
      UPDATE #{temp_patient_outcomes(start: start)} SET step = 0 WHERE step >= #{portion ? 1 : 4}
    SQL
  end

  # ===================================
  #  Cohort Table Data Management Region
  # ===================================
  def truncate_cohort_tables
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_cohort_members}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_earliest_start_date}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_other_patient_types}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_register_start_date}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_order_details}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_art_start_date}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_patient_tb_status}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_latest_tb_status}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{tmp_max_adherence}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_pregnant_obs}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_patient_side_effects}")
  end

  # ===================================
  #  Outcome Table Data Management Region
  # ===================================
  def truncate_outcome_tables(start: false)
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_patient_outcomes(start: start)}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_max_drug_orders(start: start)}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_min_auto_expire_date(start: start)}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_max_patient_state(start: start)}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_current_state(start: start)}")
    ActiveRecord::Base.connection.execute("TRUNCATE #{temp_current_medication(start: start)}")
  end

  public

  # ===================================
  #  Cleanup Methods - Drop Location-Specific Tables
  # ===================================

  # Drop all location-specific temporary tables to free up database resources
  # Should be called after report generation completes
  def cleanup_temporary_tables
    return Rails.logger.info('keep_temp_tables: true — skipping cleanup of temporary tables') if @keep_temp_tables

    cleanup_cohort_tables
    cleanup_outcome_tables
    cleanup_maternal_tables
    cleanup_mysql_functions
  rescue StandardError => e
    Rails.logger.warn("Failed to cleanup temporary tables: #{e.message}")
  end

  private

  def cleanup_cohort_tables
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_cohort_members}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_earliest_start_date}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_other_patient_types}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_register_start_date}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_order_details}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_art_start_date}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_patient_tb_status}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_latest_tb_status}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{tmp_max_adherence}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_pregnant_obs}")
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_patient_side_effects}")
  end

  def cleanup_outcome_tables
    [false, true].each do |start|
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_patient_outcomes(start: start)}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_max_drug_orders(start: start)}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_min_auto_expire_date(start: start)}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_max_patient_state(start: start)}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_current_state(start: start)}")
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_current_medication(start: start)}")
    end
  end

  def cleanup_maternal_tables
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{temp_maternal_status}")
  end

  def cleanup_mysql_functions
    # Drop location-specific MySQL functions if they were created
    ActiveRecord::Base.connection.execute("DROP FUNCTION IF EXISTS #{died_in_function_name}")
  rescue StandardError => e
    Rails.logger.debug("Failed to drop MySQL functions: #{e.message}")
  end
end
