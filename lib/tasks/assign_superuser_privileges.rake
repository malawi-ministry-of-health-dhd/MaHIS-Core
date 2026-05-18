# frozen_string_literal: true

namespace :roles do
  desc 'Assign all privileges to superuser roles'
  task assign_superuser_privileges: :environment do
    puts 'Starting superuser privilege assignment...'

    superuser_roles = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser']

    all_privileges = Privilege.all
    puts "Found #{all_privileges.count} total privileges in the system"

    superuser_roles.each do |role_name|
      role = Role.find_by(role: role_name)

      if role.nil?
        puts "Role '#{role_name}' not found, creating it..."
        role = Role.create!(
          role: role_name,
          description: "#{role_name} with all system privileges",
          uuid: SecureRandom.uuid
        )
        puts "Created role: #{role_name}"
      end

      puts "\nProcessing role: #{role_name}"

      # Get currently assigned privileges
      current_privileges = role.privileges.pluck(:privilege)
      puts "  Current privileges: #{current_privileges.count}"

      # Assign all privileges to this role
      added_count = 0
      all_privileges.each do |privilege|
        unless role.privileges.exists?(privilege: privilege.privilege)
          # Use write_attribute to bypass association type check for composite keys
          role_privilege = RolePrivilege.new
          role_privilege.write_attribute(:role, role.role)
          role_privilege.write_attribute(:privilege, privilege.privilege)
          role_privilege.save!
          added_count += 1
        end
      end

      puts "  Added: #{added_count} privileges" if added_count > 0

      # Reload and verify
      role.reload
      final_count = role.privileges.count
      puts "  Final privilege count: #{final_count}"

      if final_count == all_privileges.count
        puts "  SUCCESS: #{role_name} now has ALL #{all_privileges.count} privileges"
      else
        puts "  WARNING: Expected #{all_privileges.count} but got #{final_count}"
      end
    end

    puts "\nSuperuser privilege assignment complete"
    puts "\nSummary:"
    superuser_roles.each do |role_name|
      role = Role.find_by(role: role_name)
      if role
        count = role.privileges.count
        puts "  #{role_name}: #{count} privileges"
      end
    end
  end

  desc 'Maintain superuser privileges (run periodically to keep them updated)'
  task maintain_superuser_privileges: :environment do
    puts 'Maintaining superuser privileges...'

    superuser_roles = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser']
    all_privileges = Privilege.all

    superuser_roles.each do |role_name|
      role = Role.find_by(role: role_name)
      next unless role

      missing_privileges = all_privileges.reject { |p| role.privileges.exists?(privilege: p.privilege) }

      if missing_privileges.any?
        puts "\n#{role_name} is missing #{missing_privileges.count} privileges"
        missing_privileges.each do |privilege|
          # Use write_attribute to bypass association type check for composite keys
          role_privilege = RolePrivilege.new
          role_privilege.write_attribute(:role, role.role)
          role_privilege.write_attribute(:privilege, privilege.privilege)
          role_privilege.save!
          puts "  Added: #{privilege.privilege}"
        end
        puts "  Updated #{role_name} with #{missing_privileges.count} privileges"
      else
        puts "#{role_name} has all privileges (#{all_privileges.count})"
      end
    end

    puts "\nMaintenance complete"
  end

  desc 'Show superuser privileges'
  task show_superuser_privileges: :environment do
    puts 'Superuser Privileges Report'
    puts '=' * 80

    superuser_roles = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser']
    all_privileges_count = Privilege.count

    superuser_roles.each do |role_name|
      role = Role.find_by(role: role_name)

      puts "\n#{role_name}:"
      if role
        privilege_count = role.privileges.count
        percentage = (privilege_count.to_f / all_privileges_count * 100).round(2)
        puts "  Privileges: #{privilege_count}/#{all_privileges_count} (#{percentage}%)"

        if privilege_count < all_privileges_count
          missing = all_privileges_count - privilege_count
          puts "  WARNING: Missing #{missing} privileges"
        else
          puts "  OK: Has all privileges"
        end
      else
        puts "  ERROR: Role not found"
      end
    end

    puts "\n" + '=' * 80
  end
end
