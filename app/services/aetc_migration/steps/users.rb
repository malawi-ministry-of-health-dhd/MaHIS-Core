# frozen_string_literal: true

module AetcMigration
  module Steps
    # One MaHIS user, aetc_migration (with its own person and name), owns every migrated row
    # (decisions.json: users = single_user). It has no password, so nobody can log in with it.
    # The 408 AETC users go to users_lookup in the tracking schema, so the AETC creator kept in
    # id_map can be traced back to an AETC username.
    class Users < Base
      def title
        'Migration user and AETC users lookup'
      end

      def call
        doc = run.mappings.json('users.json')
        raise Error, "users.json strategy is #{doc['strategy'].inspect}; only single_user is supported" unless
          doc['strategy'] == 'single_user'

        username = doc['target_username'].presence || 'aetc_migration'
        sql.db.transaction do
          user_id, person_id = find_or_create_user(username)
          run.tracking.save_setting('migration_user_id', user_id)
          run.tracking.save_setting('migration_person_id', person_id)
          load_lookup(doc['mappings'], user_id)
        end
        counts
      end

      private

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

      def load_lookup(users, user_id)
        sql.execute("DELETE FROM #{trk('users_lookup')}")
        sql.insert(trk('users_lookup'), users.map do |u|
          { 'source_user_id' => u['source_user_id'], 'username' => u['source_username'],
            'system_id' => u['source_system_id'], 'source_person_id' => u['source_person_id'],
            'uuid' => u['source_uuid'], 'target_user_id' => user_id, 'audit_references' => u['audit_references'] }
        end)
        count('users_lookup', users.size)
        terminal.ok("#{terminal.number(users.size)} AETC users recorded in users_lookup (all map to user_id #{user_id})")
      end
    end
  end
end
