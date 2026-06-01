# frozen_string_literal: true

class Role < ApplicationRecord
  self.table_name = 'role'
  self.primary_key = 'role' # Yes, role is the name of the primary key

  SUPERUSER_ROLES = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser'].freeze

  # include Openmrs

  belongs_to :location, foreign_key: :location_id, primary_key: :location_id, optional: true
  has_many :role_roles, foreign_key: :parent_role # A role has sub roles?
  has_many :role_privileges, foreign_key: :role, dependent: :delete_all
  has_many :privileges, through: :role_privileges, foreign_key: :role
  has_many :user_roles, foreign_key: :role, class_name: 'UserRole'
  has_many :roles, through: :user_roles, foreign_key: :role

  STANDARD_ROLE_PRIVILEGES = {
    'General Registration Clerk' => [
      'View Patients', 'Add Patients', 'Edit Patients', 'Search Patients',
      'Activate Visits', 'View Appointments', 'Add Appointments', 'Edit Appointments',
      'View Programs', 'View Enrollments'
    ],
    'Clinician' => [
      'View Patients', 'Search Patients', 'Activate Visits',
      'View Encounters', 'Add Encounters', 'Edit Encounters',
      'View Observations', 'Add Observations', 'Edit Observations',
      'View Diagnoses', 'Record Diagnosis', 'Add Diagnoses', 'Edit Diagnoses',
      'Conduct Clinical Assessment', 'View Medications', 'Add Medications',
      'Edit Medications', 'Prescribe Treatment', 'View Prescriptions',
      'Order Investigations', 'View Lab Orders', 'View Lab Results', 'View Vitals',
      'View Consultations', 'Add Consultations', 'Edit Consultations',
      'View Appointments', 'Add Appointments', 'Edit Appointments',
      'Record Patient Outcomes', 'View Programs', 'View Enrollments',
      'Enroll Patients', 'View Reports'
    ],
    'Doctor' => [
      'View Patients', 'Search Patients', 'Activate Visits',
      'View Encounters', 'Add Encounters', 'Edit Encounters',
      'View Observations', 'Add Observations', 'Edit Observations',
      'View Diagnoses', 'Record Diagnosis', 'Add Diagnoses', 'Edit Diagnoses',
      'Conduct Clinical Assessment', 'View Medications', 'Add Medications',
      'Edit Medications', 'Prescribe Treatment', 'View Prescriptions',
      'Order Investigations', 'View Lab Orders', 'View Lab Results', 'View Vitals',
      'View Consultations', 'Add Consultations', 'Edit Consultations',
      'View Appointments', 'Add Appointments', 'Edit Appointments',
      'Record Patient Outcomes', 'View Programs', 'View Enrollments',
      'Enroll Patients', 'View Reports'
    ],
    'Nurse' => [
      'View Patients', 'Search Patients', 'Activate Visits',
      'View Encounters', 'Add Encounters',
      'View Observations', 'Add Observations',
      'View Vitals', 'Capture Vitals', 'Add Vitals', 'Edit Vitals',
      'Manage Monitoring Charts', 'Support Patient Movement',
      'View Diagnoses', 'View Medications',
      'View Appointments', 'Add Appointments', 'View Programs', 'View Enrollments'
    ],
    'Pharmacist' => [
      'View Patients', 'Search Patients', 'Activate Visits',
      'View Medications', 'View Prescriptions', 'Dispense Medications',
      'View Encounters', 'View Orders', 'View Programs'
    ],
    'Provider' => [
      'View Patients', 'Search Patients', 'Activate Visits',
      'View Encounters', 'Add Encounters',
      'View Observations', 'Add Observations',
      'View Vitals', 'View Medications', 'View Programs', 'View Enrollments'
    ]
  }.freeze

  def self.sync_standard_privileges!
    added = 0
    skipped = 0
    missing_roles = []

    transaction do
      STANDARD_ROLE_PRIVILEGES.each do |role_name, privileges|
        role = find_by(role: role_name)
        next missing_roles << role_name unless role

        current = RolePrivilege.where(role: role_name).pluck(:privilege)
        (privileges - current).each do |priv_name|
          next unless Privilege.exists?(privilege: priv_name)

          rp = RolePrivilege.new
          rp.write_attribute(:role, role_name)
          rp.write_attribute(:privilege, priv_name)
          rp.save!
          added += 1
        end
        skipped += (privileges & current).size
      end
    end

    { added_privileges: added, already_existed: skipped, missing_roles: missing_roles }
  end

  def self.location_scoped?
    column_names.include?('location_id')
  end

  def self.setup_privileges_for_roles
    privileges = Privilege.all
    Role.all.each { |role| role.privileges << privileges }
  end

  def self.sync_superuser_privileges!(location_id: nil)
    all_privileges = Privilege.pluck(:privilege)

    created_roles = 0
    added_privileges = 0
    synced_roles = []

    transaction do
      SUPERUSER_ROLES.each do |role_name|
        role = find_by(role: role_name)

        if role.nil?
          role_attributes = {
            role: role_name,
            description: "#{role_name} with all system privileges",
            uuid: SecureRandom.uuid
          }
          role_attributes[:location_id] = location_id if location_scoped?
          role = create!(role_attributes)
          created_roles += 1
        end

        current_privileges = RolePrivilege.where(role: role.role).pluck(:privilege)
        missing_privileges = all_privileges - current_privileges

        missing_privileges.each do |privilege_name|
          role_privilege = RolePrivilege.new
          role_privilege.write_attribute(:role, role.role)
          role_privilege.write_attribute(:privilege, privilege_name)
          role_privilege.save!
        end

        added_privileges += missing_privileges.size
        synced_roles << {
          role: role.role,
          added_privileges: missing_privileges.size,
          privilege_count: all_privileges.size
        }
      end
    end

    {
      created_roles: created_roles,
      added_privileges: added_privileges,
      total_privileges: all_privileges.size,
      roles: synced_roles
    }
  end
end
