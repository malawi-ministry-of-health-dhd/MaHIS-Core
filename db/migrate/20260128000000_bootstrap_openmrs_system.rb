# frozen_string_literal: true
require 'digest/sha1'
require 'securerandom'

class BootstrapOpenmrsSystem < ActiveRecord::Migration[7.0]
  def up
    conn = connection

    # Disable foreign key checks
    conn.execute 'SET FOREIGN_KEY_CHECKS = 0;'

    begin
      # ================================================================
      # 1. Bootstrap SYSTEM (daemon) user — user_id = 1
      # ================================================================

      system_person_uuid = SecureRandom.uuid

      conn.execute <<~SQL
        INSERT INTO person
          (gender, creator, date_created, voided, uuid)
        VALUES
          ('U', 1, NOW(), 0, '#{system_person_uuid}');
      SQL

      system_person_id = conn.select_value <<~SQL
        SELECT person_id FROM person WHERE uuid = '#{system_person_uuid}'
      SQL

      # Password: daemon
      system_salt = SecureRandom.base64
      system_password_hash = Digest::SHA1.hexdigest("daemon#{system_salt}")

      conn.execute('TRUNCATE TABLE users;')

      conn.execute <<~SQL
        INSERT INTO users
          (
            user_id,
            username,
            password,
            salt,
            person_id,
            creator,
            date_created,
            retired,
            uuid,
            location_id
          )
        VALUES
          (
            1,
            'daemon',
            '#{system_password_hash}',
            '#{system_salt}',
            #{system_person_id},
            1,
            NOW(),
            0,
            UUID(),
            1
          );
      SQL

      # ================================================================
      # 2. Create ADMIN person
      # ================================================================

      admin_person_uuid = SecureRandom.uuid

      conn.execute <<~SQL
        INSERT INTO person
          (gender, creator, date_created, voided, uuid)
        VALUES
          ('M', 1, NOW(), 0, '#{admin_person_uuid}');
      SQL

      admin_person_id = conn.select_value <<~SQL
        SELECT person_id FROM person WHERE uuid = '#{admin_person_uuid}'
      SQL

      conn.execute <<~SQL
        INSERT INTO person_name
          (
            person_id,
            given_name,
            family_name,
            preferred,
            creator,
            date_created,
            voided,
            uuid
          )
        VALUES
          (
            #{admin_person_id},
            'Admin',
            'User',
            1,
            1,
            NOW(),
            0,
            UUID()
          );
      SQL

      # ================================================================
      # 3. Create ADMIN user
      # ================================================================

      admin_salt = SecureRandom.base64
      admin_password = 'Admin123'
      admin_password_hash = Digest::SHA1.hexdigest("#{admin_password}#{admin_salt}")

      conn.execute <<~SQL
        INSERT INTO users
          (
            username,
            password,
            salt,
            person_id,
            creator,
            date_created,
            retired,
            uuid,
            location_id
          )
        VALUES
          (
            'admin',
            '#{admin_password_hash}',
            '#{admin_salt}',
            #{admin_person_id},
            1,
            NOW(),
            0,
            UUID(),
            1
          );
      SQL

      admin_user_id = conn.select_value <<~SQL
        SELECT user_id FROM users WHERE username = 'admin'
      SQL

      # ================================================================
      # 4. Assign Superuser role
      # ================================================================

      conn.execute <<~SQL
        INSERT INTO user_role (user_id, role)
        VALUES (#{admin_user_id}, 'Superuser');
      SQL

      # ================================================================
      # 5. Create UserProperty records for password management
      # ================================================================

      system_user_id = conn.select_value <<~SQL
        SELECT user_id FROM users WHERE username = 'daemon'
      SQL

      [system_user_id, admin_user_id].each do |user_id|
        conn.execute <<~SQL
          INSERT INTO user_property
            (user_id, property, property_value)
          VALUES
            (#{user_id}, 'last_password_updated', '#{Time.now.iso8601}');
        SQL
      end

      puts 'OpenMRS bootstrap users created'
    ensure
      # Re-enable foreign key checks
      conn.execute 'SET FOREIGN_KEY_CHECKS = 1;'
    end
  end

  def down
    # Don't drop users on rollback
  end
end