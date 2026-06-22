class EnsureSupervisionRoles < ActiveRecord::Migration[8.1]
  ROLE_DESCRIPTIONS = {
    'Nurse' => 'Licensed nurse role',
    'Clinician' => 'Licensed clinician role',
    'Student Nurse' => 'Student nurse role requiring supervising nurse at login',
    'Intern Nurse' => 'Intern nurse role',
    'Student Clinician' => 'Student clinician role requiring supervising clinician at login',
    'Intern Clinician' => 'Intern clinician role requiring supervising clinician at login'
  }.freeze

  CLINICIAN_PRIVILEGES = [
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
  ].freeze

  NURSE_PRIVILEGES = [
    'View Patients', 'Search Patients', 'Activate Visits',
    'View Encounters', 'Add Encounters',
    'View Observations', 'Add Observations',
    'View Vitals', 'Capture Vitals', 'Add Vitals', 'Edit Vitals',
    'Manage Monitoring Charts', 'Support Patient Movement',
    'View Diagnoses', 'View Medications',
    'View Appointments', 'Add Appointments', 'View Programs', 'View Enrollments'
  ].freeze

  ROLE_PRIVILEGES = {
    'Nurse' => NURSE_PRIVILEGES,
    'Intern Nurse' => NURSE_PRIVILEGES,
    'Student Nurse' => NURSE_PRIVILEGES,
    'Clinician' => CLINICIAN_PRIVILEGES,
    'Intern Clinician' => CLINICIAN_PRIVILEGES,
    'Student Clinician' => CLINICIAN_PRIVILEGES
  }.freeze

  def up
    ROLE_DESCRIPTIONS.each do |role_name, description|
      ensure_role(role_name, description)
    end

    ROLE_PRIVILEGES.each do |role_name, privileges|
      privileges.each do |privilege_name|
        ensure_role_privilege(role_name, privilege_name)
      end
    end
  end

  def down
    trainee_roles = ['Student Nurse', 'Intern Nurse', 'Student Clinician', 'Intern Clinician']
    trainee_roles.each do |role_name|
      execute <<~SQL.squish
        DELETE FROM role_privilege
        WHERE role = #{quote(role_name)}
      SQL

      execute <<~SQL.squish
        DELETE FROM role
        WHERE role = #{quote(role_name)}
      SQL
    end
  end

  private

  def ensure_role(role_name, description)
    return if select_value("SELECT COUNT(*) FROM role WHERE role = #{quote(role_name)}").to_i.positive?

    columns = %w[role description uuid]
    values = [quote(role_name), quote(description), quote(SecureRandom.uuid)]

    if column_exists?(:role, :location_id)
      columns << 'location_id'
      values << 'NULL'
    end

    execute <<~SQL.squish
      INSERT INTO role (#{columns.join(', ')})
      VALUES (#{values.join(', ')})
    SQL
  end

  def ensure_role_privilege(role_name, privilege_name)
    return unless select_value("SELECT COUNT(*) FROM privilege WHERE privilege = #{quote(privilege_name)}").to_i.positive?
    return if select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM role_privilege
      WHERE role = #{quote(role_name)}
        AND privilege = #{quote(privilege_name)}
    SQL

    execute <<~SQL.squish
      INSERT INTO role_privilege (role, privilege)
      VALUES (#{quote(role_name)}, #{quote(privilege_name)})
    SQL
  end
end
