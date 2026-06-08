# frozen_string_literal: true
#
# Assigns default privileges to standard clinical roles.
# Safe to re-run — uses find_or_create semantics on role_privilege.

ROLE_PRIVILEGE_MAP = {
  'General Registration Clerk' => %w[
    View\ Patients
    Add\ Patients
    Edit\ Patients
    Search\ Patients
    Activate\ Visits
    View\ Appointments
    Add\ Appointments
    Edit\ Appointments
    View\ Programs
    View\ Enrollments
  ],

  'Clinician' => %w[
    View\ Patients
    Search\ Patients
    Activate\ Visits
    View\ Encounters
    Add\ Encounters
    Edit\ Encounters
    View\ Observations
    Add\ Observations
    Edit\ Observations
    View\ Diagnoses
    Record\ Diagnosis
    Add\ Diagnoses
    Edit\ Diagnoses
    Conduct\ Clinical\ Assessment
    View\ Medications
    Add\ Medications
    Edit\ Medications
    Prescribe\ Treatment
    View\ Prescriptions
    Order\ Investigations
    View\ Lab\ Orders
    View\ Lab\ Results
    View\ Vitals
    View\ Consultations
    Add\ Consultations
    Edit\ Consultations
    View\ Appointments
    Add\ Appointments
    Edit\ Appointments
    Record\ Patient\ Outcomes
    View\ Programs
    View\ Enrollments
    Enroll\ Patients
    View\ Reports
  ],

  'Doctor' => %w[
    View\ Patients
    Search\ Patients
    Activate\ Visits
    View\ Encounters
    Add\ Encounters
    Edit\ Encounters
    View\ Observations
    Add\ Observations
    Edit\ Observations
    View\ Diagnoses
    Record\ Diagnosis
    Add\ Diagnoses
    Edit\ Diagnoses
    Conduct\ Clinical\ Assessment
    View\ Medications
    Add\ Medications
    Edit\ Medications
    Prescribe\ Treatment
    View\ Prescriptions
    Order\ Investigations
    View\ Lab\ Orders
    View\ Lab\ Results
    View\ Vitals
    View\ Consultations
    Add\ Consultations
    Edit\ Consultations
    View\ Appointments
    Add\ Appointments
    Edit\ Appointments
    Record\ Patient\ Outcomes
    View\ Programs
    View\ Enrollments
    Enroll\ Patients
    View\ Reports
  ],

  'Nurse' => %w[
    View\ Patients
    Search\ Patients
    Activate\ Visits
    View\ Encounters
    Add\ Encounters
    View\ Observations
    Add\ Observations
    View\ Vitals
    Capture\ Vitals
    Add\ Vitals
    Edit\ Vitals
    View\ Diagnoses
    View\ Medications
    View\ Appointments
    Add\ Appointments
    View\ Programs
    View\ Enrollments
    Support\ Patient\ Movement
    Manage\ Monitoring\ Charts
  ],

  'Pharmacist' => %w[
    View\ Patients
    Search\ Patients
    Activate\ Visits
    View\ Medications
    View\ Prescriptions
    Dispense\ Medications
    View\ Encounters
    View\ Orders
    View\ Programs
  ],

  'Lab Technician' => %w[
    View\ Patients
    Search\ Patients
    View\ Lab\ Orders
    Enter\ Laboratory\ Results
    Add\ Lab\ Results
    Edit\ Lab\ Results
    View\ Lab\ Results
    View\ Programs
  ],

  'Provider' => %w[
    View\ Patients
    Search\ Patients
    Activate\ Visits
    View\ Encounters
    Add\ Encounters
    View\ Observations
    Add\ Observations
    View\ Vitals
    View\ Medications
    View\ Programs
    View\ Enrollments
  ],
}.freeze

added = 0
skipped = 0

ROLE_PRIVILEGE_MAP.each do |role_name, privileges|
  role = Role.find_by(role: role_name)

  unless role
    puts "  SKIP  Role '#{role_name}' not found in database — skipping"
    next
  end

  privileges.each do |privilege_name|
    privilege = Privilege.find_by(privilege: privilege_name)

    unless privilege
      puts "  SKIP  Privilege '#{privilege_name}' not found — skipping"
      next
    end

    if RolePrivilege.exists?(role: role_name, privilege: privilege_name)
      skipped += 1
      next
    end

    rp = RolePrivilege.new
    rp.write_attribute(:role, role_name)
    rp.write_attribute(:privilege, privilege_name)
    rp.save!
    added += 1
    puts "  ADD   #{role_name} ← #{privilege_name}"
  end
end

puts "\nDone. Added #{added} role-privilege assignments, #{skipped} already existed."
