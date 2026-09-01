# frozen_string_literal: true

# Supervised users - students and interns - are at a facility for a fixed
# rotation, but their accounts previously outlived it: nothing expired, so an
# account stayed usable long after the person had left.
#
# Their last valid day is now held as the `account_expires_on` user_property.
# This migration changes no schema; it only gives the accounts that already exist
# a period, so the policy applies to them too rather than only to users created
# from here on.
class BackfillSupervisedAccountPeriods < ActiveRecord::Migration[8.1]
  def up
    expires_on = (Date.current + UserService::DEFAULT_ACCOUNT_DURATION_DAYS).iso8601

    say_with_time "Giving existing supervised accounts a period ending #{expires_on}" do
      execute(<<~SQL.squish)
        INSERT INTO user_property (user_id, property, property_value)
        SELECT u.user_id,
               #{quote(UserService::ACCOUNT_EXPIRY_PROPERTY)},
               #{quote(expires_on)}
          FROM users u
         WHERE u.deactivated_on IS NULL
           AND EXISTS (
                 SELECT 1
                   FROM user_role ur
                  WHERE ur.user_id = u.user_id
                    AND ur.role IN (#{supervised_roles_sql})
               )
           AND NOT EXISTS (
                 SELECT 1
                   FROM user_property up
                  WHERE up.user_id = u.user_id
                    AND up.property = #{quote(UserService::ACCOUNT_EXPIRY_PROPERTY)}
               )
      SQL
    end
  end

  # Removes only the periods this migration could have created. Accounts set up
  # by hand since deploy are left alone, since their dates were chosen by a
  # supervisor rather than by us.
  def down
    expires_on = (Date.current + UserService::DEFAULT_ACCOUNT_DURATION_DAYS).iso8601

    execute(<<~SQL.squish)
      DELETE FROM user_property
       WHERE property = #{quote(UserService::ACCOUNT_EXPIRY_PROPERTY)}
         AND property_value = #{quote(expires_on)}
    SQL
  end

  private

  # Counted from today, NOT from each user's date_created: counting from creation
  # would expire every intern already past 90 days the moment this ran, locking
  # them out mid-shift with no warning. Starting the clock now gives everyone one
  # clear rotation and supervisors time to extend the accounts that need it.
  def supervised_roles_sql
    LoginResponseService::SUPERVISION_REQUIREMENTS.keys.map { |role| quote(role) }.join(', ')
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
