# frozen_string_literal: true

namespace :roles do
  WORKFLOW_ROLE_PRIVILEGES = {
    'Registration Clerk' => %w[
      View\ Patients
      Add\ Patients
      Edit\ Patients
      Search\ Patients
      Activate\ Visits
    ].freeze,
    'General Registration Clerk' => %w[
      View\ Patients
      Add\ Patients
      Edit\ Patients
      Search\ Patients
      Activate\ Visits
    ].freeze,
    'Nurse' => %w[
      View\ Patients
      Add\ Patients
      Edit\ Patients
      Search\ Patients
      Activate\ Visits
      View\ Vitals
      Capture\ Vitals
      Add\ Vitals
      Edit\ Vitals
      Manage\ Monitoring\ Charts
      Support\ Patient\ Movement
    ].freeze,
    'Clinician' => %w[
      View\ Patients
      Add\ Patients
      Edit\ Patients
      Search\ Patients
      Activate\ Visits
      View\ Vitals
      Capture\ Vitals
      Add\ Vitals
      Edit\ Vitals
      Manage\ Monitoring\ Charts
      Support\ Patient\ Movement
      Conduct\ Clinical\ Assessment
      Order\ Investigations
      Record\ Diagnosis
      Add\ Diagnoses
      Edit\ Diagnoses
      Prescribe\ Treatment
      Add\ Medications
      Edit\ Medications
      Record\ Patient\ Outcomes
    ].freeze,
    'Lab' => %w[
      View\ Lab\ Orders
      View\ Lab\ Results
      Enter\ Laboratory\ Results
      Add\ Lab\ Results
      Edit\ Lab\ Results
    ].freeze,
    'Pharmacist' => %w[
      View\ Prescriptions
      View\ Medications
      Dispense\ Medications
    ].freeze
  }.freeze

  def ensure_role_privilege!(role_name, privilege_name)
    existing_assignment = RolePrivilege.find_by(role: role_name, privilege: privilege_name)
    return false if existing_assignment.present?

    role_privilege = RolePrivilege.new
    role_privilege.write_attribute(:role, role_name)
    role_privilege.write_attribute(:privilege, privilege_name)
    role_privilege.save!

    true
  end

  desc 'Assign workflow privileges to existing operational roles'
  task assign_workflow_privileges: :environment do
    puts 'Assigning workflow privileges to existing roles...'

    WORKFLOW_ROLE_PRIVILEGES.each do |role_name, privilege_names|
      role = Role.find_by(role: role_name)

      unless role
        puts "Skipping '#{role_name}': role not found"
        next
      end

      puts "\nProcessing role: #{role_name}"

      missing_privileges = privilege_names.reject { |privilege_name| Privilege.exists?(privilege: privilege_name) }
      if missing_privileges.any?
        puts "  Missing privilege definitions: #{missing_privileges.join(', ')}"
      end

      added_count = 0
      privilege_names.each do |privilege_name|
        next unless Privilege.exists?(privilege: privilege_name)

        added_count += 1 if ensure_role_privilege!(role.role, privilege_name)
      end

      role.reload
      assigned_privileges = role.privileges.where(privilege: privilege_names).pluck(:privilege).sort

      puts "  Added #{added_count} privilege(s)"
      puts "  Assigned #{assigned_privileges.count}/#{privilege_names.count} mapped privilege(s)"
      puts "  Current mapped privileges: #{assigned_privileges.join(', ')}" if assigned_privileges.any?
    end

    puts "\nWorkflow privilege assignment complete."
  end

  desc 'Show workflow privilege mappings for operational roles'
  task show_workflow_privileges: :environment do
    puts 'Workflow role privilege mappings'
    puts '=' * 80

    WORKFLOW_ROLE_PRIVILEGES.each do |role_name, privilege_names|
      role = Role.find_by(role: role_name)

      puts "\n#{role_name}:"
      unless role
        puts '  Role not found'
        next
      end

      assigned = role.privileges.where(privilege: privilege_names).pluck(:privilege).sort
      missing = privilege_names - assigned

      puts "  Assigned: #{assigned.count}/#{privilege_names.count}"
      puts "  Privileges: #{assigned.join(', ')}" if assigned.any?
      puts "  Missing: #{missing.join(', ')}" if missing.any?
    end

    puts "\n" + ('=' * 80)
  end
end
