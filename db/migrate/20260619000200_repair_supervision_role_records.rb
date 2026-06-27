class RepairSupervisionRoleRecords < ActiveRecord::Migration[8.1]
  ROLE_DESCRIPTIONS = {
    'Nurse' => 'Licensed nurse role',
    'Clinician' => 'Licensed clinician role',
    'Student Nurse' => 'Student nurse role requiring supervising nurse at login',
    'Intern Nurse' => 'Intern nurse role',
    'Student Clinician' => 'Student clinician role requiring supervising clinician at login',
    'Intern Clinician' => 'Intern clinician role requiring supervising clinician at login'
  }.freeze

  def up
    ROLE_DESCRIPTIONS.each do |role_name, description|
      next if select_value("SELECT COUNT(*) FROM role WHERE role = #{quote(role_name)}").to_i.positive?

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
  end

  def down
    # Intentionally no-op: these roles may already be assigned to users.
  end
end
