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
