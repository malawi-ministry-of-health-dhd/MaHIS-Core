# frozen_string_literal: true

privileges = [
  # User Management
  { privilege: 'View Users', description: 'Allows viewing user accounts and their details' },
  { privilege: 'Add Users', description: 'Allows creating new user accounts' },
  { privilege: 'Edit Users', description: 'Allows editing existing user account information' },
  { privilege: 'Delete Users', description: 'Allows deleting user accounts' },

  # Role Management
  { privilege: 'View Roles', description: 'Allows viewing roles and their permissions' },
  { privilege: 'Add Roles', description: 'Allows creating new roles' },
  { privilege: 'Edit Roles', description: 'Allows editing existing roles and their permissions' },
  { privilege: 'Delete Roles', description: 'Allows deleting roles' },

  # Privilege Management
  { privilege: 'View Privileges', description: 'Allows viewing system privileges' },
  { privilege: 'Add Privileges', description: 'Allows creating new privileges' },
  { privilege: 'Edit Privileges', description: 'Allows editing existing privileges' },
  { privilege: 'Delete Privileges', description: 'Allows deleting privileges' },

  # Patient Management
  { privilege: 'View Patients', description: 'Allows viewing patient records' },
  { privilege: 'Add Patients', description: 'Allows registering new patients' },
  { privilege: 'Edit Patients', description: 'Allows editing patient information' },
  { privilege: 'Delete Patients', description: 'Allows voiding patient records' },

  # Encounter Management
  { privilege: 'View Encounters', description: 'Allows viewing patient encounters' },
  { privilege: 'Add Encounters', description: 'Allows creating new patient encounters' },
  { privilege: 'Edit Encounters', description: 'Allows editing patient encounters' },
  { privilege: 'Delete Encounters', description: 'Allows voiding patient encounters' },

  # Observation Management
  { privilege: 'View Observations', description: 'Allows viewing patient observations' },
  { privilege: 'Add Observations', description: 'Allows creating new observations' },
  { privilege: 'Edit Observations', description: 'Allows editing observations' },
  { privilege: 'Delete Observations', description: 'Allows voiding observations' },

  # Order Management
  { privilege: 'View Orders', description: 'Allows viewing patient orders' },
  { privilege: 'Add Orders', description: 'Allows creating new orders' },
  { privilege: 'Edit Orders', description: 'Allows editing orders' },
  { privilege: 'Delete Orders', description: 'Allows voiding orders' },

  # Lab Management
  { privilege: 'View Lab Results', description: 'Allows viewing lab results' },
  { privilege: 'Add Lab Results', description: 'Allows entering lab results' },
  { privilege: 'Edit Lab Results', description: 'Allows editing lab results' },
  { privilege: 'Delete Lab Results', description: 'Allows voiding lab results' },

  # Vitals Management
  { privilege: 'View Vitals', description: 'Allows viewing patient vital signs' },
  { privilege: 'Add Vitals', description: 'Allows recording patient vital signs' },
  { privilege: 'Edit Vitals', description: 'Allows editing patient vital signs' },
  { privilege: 'Delete Vitals', description: 'Allows voiding vital sign records' },

  # Medication Management
  { privilege: 'View Medications', description: 'Allows viewing medication prescriptions' },
  { privilege: 'Add Medications', description: 'Allows prescribing medications' },
  { privilege: 'Edit Medications', description: 'Allows editing medication prescriptions' },
  { privilege: 'Delete Medications', description: 'Allows voiding medication prescriptions' },
  { privilege: 'Dispense Medications', description: 'Allows dispensing medications to patients' },

  # Diagnosis Management
  { privilege: 'View Diagnoses', description: 'Allows viewing patient diagnoses' },
  { privilege: 'Add Diagnoses', description: 'Allows recording patient diagnoses' },
  { privilege: 'Edit Diagnoses', description: 'Allows editing patient diagnoses' },
  { privilege: 'Delete Diagnoses', description: 'Allows voiding patient diagnoses' },

  # Treatment Plan Management
  { privilege: 'View Treatment Plans', description: 'Allows viewing treatment plans' },
  { privilege: 'Add Treatment Plans', description: 'Allows creating treatment plans' },
  { privilege: 'Edit Treatment Plans', description: 'Allows editing treatment plans' },
  { privilege: 'Delete Treatment Plans', description: 'Allows voiding treatment plans' },

  # Consultation Management
  { privilege: 'View Consultations', description: 'Allows viewing patient consultations' },
  { privilege: 'Add Consultations', description: 'Allows creating patient consultations' },
  { privilege: 'Edit Consultations', description: 'Allows editing patient consultations' },
  { privilege: 'Delete Consultations', description: 'Allows voiding patient consultations' },

  # Appointment Management
  { privilege: 'View Appointments', description: 'Allows viewing patient appointments' },
  { privilege: 'Add Appointments', description: 'Allows scheduling patient appointments' },
  { privilege: 'Edit Appointments', description: 'Allows editing patient appointments' },
  { privilege: 'Delete Appointments', description: 'Allows canceling patient appointments' },

  # Report Management
  { privilege: 'View Reports', description: 'Allows viewing system reports' },
  { privilege: 'Generate Reports', description: 'Allows generating system reports' },
  { privilege: 'Export Reports', description: 'Allows exporting reports to files' },

  # Program Management
  { privilege: 'View Programs', description: 'Allows viewing programs' },
  { privilege: 'Manage Programs', description: 'Allows managing program configurations' },
  { privilege: 'Enroll Patients', description: 'Allows enrolling patients into programs' },
  { privilege: 'View Enrollments', description: 'Allows viewing patient program enrollments' },
  { privilege: 'Edit Enrollments', description: 'Allows editing patient program enrollments' },
  { privilege: 'Delete Enrollments', description: 'Allows removing patients from programs' },

  # System Administration
  { privilege: 'System Administration', description: 'Full system administration access' },
  { privilege: 'View Audit Logs', description: 'Allows viewing system audit logs' },
  { privilege: 'Manage System Settings', description: 'Allows managing system configuration settings' }
]

privileges.each do |priv_data|
  privilege = Privilege.find_or_initialize_by(privilege: priv_data[:privilege])
  privilege.description = priv_data[:description]
  if privilege.new_record?
    privilege.uuid = SecureRandom.uuid
  end

  privilege.save!
  puts "Created/Updated privilege: #{priv_data[:privilege]}"
end

puts "Seeded #{privileges.count} privileges successfully!"
