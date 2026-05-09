# frozen_string_literal: true

namespace :user do
  namespace :role do
    desc 'Add Enrollment Clerk role to a user'
    task :add_enrollment_clerk, [:username] => :environment do |_task, args|
      username = args[:username]

      unless username
        puts "Usage: rake user:role:add_enrollment_clerk[username]"
        puts "Example: rake user:role:add_enrollment_clerk[testclerk]"
        exit 1
      end

      user = User.find_by(username: username)
      unless user
        puts "Error: User '#{username}' not found"
        exit 1
      end

      # Check if Enrollment Clerk role exists, create if not
      role = Role.find_by(role: 'Enrollment Clerk')
      unless role
        role = Role.create(
          role: 'Enrollment Clerk',
          description: 'Clerk authorized to enroll patients in programs',
          uuid: SecureRandom.uuid
        )
        puts "Created new role: Enrollment Clerk"
      end

      # Check if user already has this role
      existing = ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM user_role WHERE user_id = #{user.user_id} AND role = '#{role.role}'"
      )

      if existing.to_i > 0
        puts "User '#{username}' already has Enrollment Clerk role"
        exit 0
      end

      # Add role to user using raw SQL since UserRole has composite primary key
      ActiveRecord::Base.connection.execute(
        "INSERT INTO user_role (user_id, role) VALUES (#{user.user_id}, '#{role.role}')"
      )

      puts "✓ Successfully added Enrollment Clerk role to user '#{username}'"
      puts "User ID: #{user.user_id}"
      puts "Roles: #{user.roles.map(&:role).join(', ')}"
    end

    desc 'Remove Enrollment Clerk role from a user'
    task :remove_enrollment_clerk, [:username] => :environment do |_task, args|
      username = args[:username]

      unless username
        puts "Usage: rake user:role:remove_enrollment_clerk[username]"
        puts "Example: rake user:role:remove_enrollment_clerk[testclerk]"
        exit 1
      end

      user = User.find_by(username: username)
      unless user
        puts "Error: User '#{username}' not found"
        exit 1
      end

      # Find and delete the user_role record using raw SQL
      result = ActiveRecord::Base.connection.execute(
        "DELETE FROM user_role WHERE user_id = #{user.user_id} AND role = 'Enrollment Clerk'"
      )

      if result.affected_rows == 0
        puts "User '#{username}' does not have Enrollment Clerk role"
        exit 0
      end
      puts "✓ Successfully removed Enrollment Clerk role from user '#{username}'"
      puts "Remaining roles: #{user.roles.map(&:role).join(', ')}"
    end

    desc 'List all users with Enrollment Clerk role'
    task list_enrollment_clerks: :environment do
      enrollment_clerks = User.joins(:roles)
                              .where(user_role: { role: 'Enrollment Clerk' })
                              .select('users.username, users.user_id')

      if enrollment_clerks.empty?
        puts "No users found with Enrollment Clerk role"
      else
        puts "Users with Enrollment Clerk role:"
        puts "─" * 40
        enrollment_clerks.each do |user|
          puts "  #{user.username} (ID: #{user.user_id})"
        end
        puts "─" * 40
        puts "Total: #{enrollment_clerks.count}"
      end
    end
  end
end
