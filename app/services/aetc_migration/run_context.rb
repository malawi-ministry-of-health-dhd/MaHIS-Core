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

    private

    def setting!(name)
      value = tracking.setting(name)
      raise Error, "#{name} is not set yet: run the users step first (rake \"aetc:migrate[users]\")" if value.blank?

      value.to_i
    end
  end
end
