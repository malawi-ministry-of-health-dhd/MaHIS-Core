# frozen_string_literal: true

require 'csv'

module AetcMigration
  module Steps
    # Every AETC user becomes a MaHIS user (decisions.json: users = per_user), so migrated rows keep who
    # created, changed and voided them.
    #   * A username (or system_id) MaHIS already has gets _aetc appended (then _aetc2, _aetc3, ...);
    #     the renamed users are logged (username_taken) and listed in a CSV under log/aetc_migration/.
    #   * No password: an admin sets one before the first login. AETC retired users stay retired.
    #   * location_id and program access from users.json (QECH 1291, AETC program 30).
    #   * AETC roles that exist in MaHIS are copied; the others are logged (role_not_in_mahis).
    #   * The user's person is migrated by the persons step, which then links it (person_id points at
    #     the aetc_migration person until then).
    #   * An AETC user whose uuid MaHIS already has is mapped to that MaHIS user, not created again.
    # The aetc_migration user (no password, never retired) still owns the new accounts and stands in for
    # AETC user ids that no longer exist. users_lookup maps each AETC user to its MaHIS user.
    class Users < Base
      SUFFIX = '_aetc'

      def title
        'Users'
      end

      def call
        doc = run.mappings.json('users.json')
        raise Error, "users.json strategy is #{doc['strategy'].inspect}; only per_user is supported" unless
          doc['strategy'] == 'per_user'

        refuse_older_run
        recorder = Recorder.new(sql, run.tracking, key)
        sql.db.transaction do
          user_id, person_id = find_or_create_user(doc['target_username'].presence || 'aetc_migration')
          run.tracking.save_setting('migration_user_id', user_id)
          run.tracking.save_setting('migration_person_id', person_id)
          migrate_users(doc, user_id, person_id, recorder)
          recorder.flush
          load_lookup(doc['mappings'], user_id)
        end
        write_renamed_csv
        counts
      end

      private

      # A run that migrated persons before AETC users became MaHIS users has every row owned by
      # aetc_migration; adding the users now would leave those rows unattributed.
      def refuse_older_run
        return if run.tracking.checkpoint('persons').zero?
        return if sql.value("SELECT COUNT(*) FROM #{trk('id_map')} WHERE entity = 'user'").to_i.positive?

        raise Error, "#{run.tracking.name} migrated persons before AETC users were migrated as MaHIS users. " \
                     'Restore the MaHIS backup taken before that run, drop this tracking schema ' \
                     '(rake aetc:cleanup) and migrate again.'
      end

      def find_or_create_user(username)
        existing = sql.select("SELECT user_id, person_id FROM #{tgt('users')} WHERE username = #{sql.quote(username)}").first
        if existing
          terminal.ok("Migration user #{username} already exists (user_id #{existing['user_id']})")
          return [existing['user_id'], existing['person_id']]
        end

        creator = run.config.creator_user_id
        now = Time.current
        person_uuid = SecureRandom.uuid
        sql.insert(tgt('person'), [{ 'gender' => nil, 'birthdate_estimated' => 0, 'dead' => 0, 'creator' => creator,
                                     'date_created' => now, 'voided' => 0, 'uuid' => person_uuid }])
        person_id = sql.ids_by_uuid(tgt('person'), 'person_id', [person_uuid]).fetch(person_uuid)
        sql.insert(tgt('person_name'), [{ 'preferred' => 1, 'person_id' => person_id, 'given_name' => 'AETC',
                                          'family_name' => 'Migration', 'creator' => creator, 'date_created' => now,
                                          'voided' => 0, 'uuid' => SecureRandom.uuid }])
        user_uuid = SecureRandom.uuid
        sql.insert(tgt('users'), [{ 'system_id' => username, 'username' => username, 'password' => nil, 'salt' => nil,
                                    'creator' => creator, 'date_created' => now, 'person_id' => person_id,
                                    'retired' => 0, 'uuid' => user_uuid }])
        user_id = sql.ids_by_uuid(tgt('users'), 'user_id', [user_uuid]).fetch(user_uuid)
        count('users', 1)
        count('person', 1)
        terminal.ok("Created migration user #{username} (user_id #{user_id}, person_id #{person_id}, no password)")
        [user_id, person_id]
      end

      def migrate_users(doc, migration_user, migration_person, rec)
        users = sql.select("SELECT * FROM #{src('users')} ORDER BY user_id")
        already = mapped_ids('user', users.map { |u| u['user_id'] })
        taken = sql.select("SELECT user_id, username, system_id FROM #{tgt('users')}")
        usernames = taken.to_h { |u| [u['username'].to_s.downcase, u['user_id']] }
        system_ids = taken.to_h { |u| [u['system_id'].to_s.downcase, u['user_id']] }
        by_uuid = sql.ids_by_uuid(tgt('users'), 'user_id', users.map { |u| u['uuid'] })
        roles = sql.values("SELECT role FROM #{tgt('role')}").to_set
        now = Time.current

        users.each do |u|
          next if already.key?(u['user_id'])

          if by_uuid.key?(u['uuid'])
            rec.logged('user', u['user_id'], 'uuid_exists_in_target', "MaHIS user_id=#{by_uuid[u['uuid']]}")
            rec.mapped('user', u, 'user_id', by_uuid[u['uuid']], u['uuid'])
            next
          end

          wanted = u['username'].presence || u['system_id']
          username = free_name(wanted, usernames)
          system_id = free_name(u['system_id'].presence || wanted, system_ids)
          if username != wanted
            rec.logged('user', u['user_id'], 'username_taken',
                       "#{wanted} -> #{username} (MaHIS user_id #{usernames[wanted.to_s.downcase]} has #{wanted})")
          end
          retired = truthy?(u['retired'])
          sql.insert(tgt('users'), [{ 'system_id' => system_id, 'username' => username, 'password' => nil, 'salt' => nil,
                                      'creator' => migration_user, 'date_created' => u['date_created'] || EPOCH,
                                      'person_id' => migration_person, 'retired' => retired ? 1 : 0,
                                      'retired_by' => retired ? migration_user : nil, 'date_retired' => u['date_retired'],
                                      'retire_reason' => u['retire_reason'], 'uuid' => u['uuid'],
                                      'location_id' => doc['target_location_id']&.to_s }])
          user_id = sql.value('SELECT LAST_INSERT_ID()').to_i
          usernames[username.downcase] = user_id
          system_ids[system_id.downcase] = user_id
          rec.mapped('user', u, 'user_id', user_id, u['uuid'])
          count('users', 1)
          add_roles(u['user_id'], user_id, roles, rec)
          add_program(user_id, doc['target_program_id'], now)
        end
      end

      # name, or name_aetc, name_aetc2, ... whichever MaHIS does not have yet (case-insensitive).
      def free_name(name, taken)
        return name unless taken.key?(name.to_s.downcase)

        candidate = "#{name}#{SUFFIX}"
        n = 1
        candidate = "#{name}#{SUFFIX}#{n += 1}" while taken.key?(candidate.downcase)
        candidate
      end

      def add_roles(source_user_id, user_id, roles, rec)
        sql.values("SELECT role FROM #{src('user_role')} WHERE user_id = #{source_user_id.to_i} ORDER BY role").each do |role|
          if roles.include?(role)
            sql.execute("INSERT IGNORE INTO #{tgt('user_role')} (user_id, role) VALUES (#{user_id}, #{sql.quote(role)})")
            count('user_role', 1)
          else
            rec.logged('user_role', source_user_id, 'role_not_in_mahis', role)
          end
        end
      end

      def add_program(user_id, program_id, now)
        return if program_id.blank?

        sql.insert(tgt('user_programs'), [{ 'user_id' => user_id, 'program_id' => program_id, 'voided' => 0,
                                            'created_at' => now, 'updated_at' => now }])
        count('user_programs', 1)
      end

      # AETC user id -> MaHIS user id, for every step's creator/changed_by/voided_by.
      def load_lookup(mappings, migration_user)
        references = (mappings || []).to_h { |m| [m['source_user_id'], m['audit_references']] }
        users = sql.select("SELECT u.user_id, u.username, u.system_id, u.person_id, u.uuid, m.tgt_id " \
                           "FROM #{src('users')} u LEFT JOIN #{trk('id_map')} m ON m.entity = 'user' AND m.src_id = u.user_id")
        sql.execute("DELETE FROM #{trk('users_lookup')}")
        sql.insert(trk('users_lookup'), users.map do |u|
          { 'source_user_id' => u['user_id'], 'username' => u['username'], 'system_id' => u['system_id'],
            'source_person_id' => u['person_id'], 'uuid' => u['uuid'], 'target_user_id' => u['tgt_id'] || migration_user,
            'audit_references' => references[u['user_id']] }
        end)
        count('users_lookup', users.size)
        terminal.ok("#{terminal.number(users.size)} AETC users in users_lookup, each mapped to its own MaHIS user")
      end

      # Every AETC user whose username was taken in MaHIS (this run and earlier ones).
      def write_renamed_csv
        renamed = sql.select("SELECT src_id, detail FROM #{trk('migration_log')} " \
                             "WHERE step = 'users' AND reason = 'username_taken' ORDER BY src_id")
        return terminal.ok('No AETC username was already taken in MaHIS') if renamed.empty?

        lookup = sql.select("SELECT source_user_id, username, target_user_id FROM #{trk('users_lookup')}")
                    .to_h { |u| [u['source_user_id'], u] }
        new_names = sql.select("SELECT user_id, username FROM #{tgt('users')} " \
                               "WHERE user_id IN (#{sql.list(lookup.values.map { |u| u['target_user_id'] })})")
                       .to_h { |u| [u['user_id'], u['username']] }
        dir = run.config.log_dir.join('aetc_migration')
        FileUtils.mkdir_p(dir)
        path = dir.join("#{run.tracking.name}-usernames-taken-#{Time.current.strftime('%Y%m%d-%H%M%S')}.csv")
        CSV.open(path, 'w') do |csv|
          csv << %w[aetc_user_id aetc_username existing_mahis_user_id new_mahis_user_id new_username]
          renamed.each do |r|
            u = lookup[r['src_id']] || {}
            existing = r['detail'].to_s[/MaHIS user_id (\d+)/, 1]
            csv << [r['src_id'], u['username'], existing, u['target_user_id'], new_names[u['target_user_id']]]
          end
        end
        terminal.warn("#{terminal.number(renamed.size)} AETC usernames were already taken in MaHIS; list: #{path}")
      end
    end
  end
end
