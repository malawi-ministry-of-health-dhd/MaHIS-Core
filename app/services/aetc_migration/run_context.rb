# frozen_string_literal: true

module AetcMigration
  # Everything a migration step needs for one rake aetc:migrate run.
  #   cap      highest AETC person_id to migrate in this run (from LIMIT), or nil for all
  #   dry_run  the whole run happens in one transaction that is rolled back at the end
  RunContext = Struct.new(:config, :terminal, :sql, :source, :tracking, :mappings, :dry_run, :cap,
                          keyword_init: true) do
    def target
      config.target_db
    end

    def migration_user_id
      setting!('migration_user_id')
    end

    def migration_person_id
      setting!('migration_person_id')
    end

    def src(table)
      sql.name(source, table)
    end

    def tgt(table)
      sql.name(target, table)
    end

    def trk(table)
      tracking.table_name(table)
    end

    # MaHIS user for an AETC user id (users_lookup); the aetc_migration user when there is none.
    def user_for(source_user_id)
      @user_ids ||= sql.select("SELECT source_user_id, target_user_id FROM #{trk('users_lookup')}")
                       .to_h { |r| [r['source_user_id'], r['target_user_id']] }
      @user_ids.fetch(source_user_id.to_i, migration_user_id)
    end

    # SQL for the same, given an AETC user id column.
    def user_sql(column)
      "COALESCE((SELECT ul.target_user_id FROM #{trk('users_lookup')} ul WHERE ul.source_user_id = #{column}), " \
        "#{migration_user_id})"
    end

    private

    def setting!(name)
      value = tracking.setting(name)
      raise Error, "#{name} is not set yet: run the users step first (rake \"aetc:migrate[users]\")" if value.blank?

      value.to_i
    end
  end
end
