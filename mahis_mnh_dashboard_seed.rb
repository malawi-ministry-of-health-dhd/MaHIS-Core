# frozen_string_literal: true

require 'json'
require 'securerandom'

PREFIX = 'MNHSEED-20260520'
TARGET_PER_MODULE = 100

GROUPS = {
  'ANC' => { program_id: 12, encounter_type: 217, given_name: 'MnhAnc' },
  'PNC' => { program_id: 35, encounter_type: 262, given_name: 'MnhPnc' },
  'LABOUR' => { program_id: 36, encounter_type: 261, given_name: 'MnhLabour' }
}.freeze

def active_seed_user
  token_cols = User.column_names
  scope = User.unscoped
  if token_cols.include?('authentication_token') && token_cols.include?('token_expiry_time')
    # Try a non-expired token first (NULL expiry = never expires — treat as valid)
    with_token = scope.where.not(authentication_token: nil)
    active = with_token.where('token_expiry_time > ?', Time.zone.now)
                       .order(token_expiry_time: :desc)
                       .first
    active ||= with_token.where(token_expiry_time: nil).first
    return active if active
  end

  scope.find_by(username: 'admin') || scope.first
end

def dummy_identifier_type
  @dummy_identifier_type ||= PatientIdentifierType.unscoped.find_or_create_by!(name: 'Dummy id') do |t|
    t.description      = 'Dummy identifier used for seeding'
    t.check_digit      = 0
    t.retired          = 0
    t.creator          = 1
    t.uuid             = SecureRandom.uuid
  end
end

def load_concepts(names)
  found = ConceptName.unscoped.where(name: names).pluck(:name, :concept_id).to_h
  missing = names - found.keys
  raise "Missing concept names in DB:\n  #{missing.join("\n  ")}" if missing.any?

  found
end

def obs_row(patient_id:, encounter_id:, concept_id:, obs_time:, user_id:, location_id:, value_coded: nil, value_text: nil,
            value_numeric: nil, value_boolean: nil)
  {
    person_id: patient_id,
    concept_id: concept_id,
    encounter_id: encounter_id,
    obs_datetime: obs_time,
    location_id: location_id.to_s,
    value_boolean: value_boolean,
    value_coded: value_coded,
    value_coded_name_id: nil,
    value_numeric: value_numeric,
    value_text: value_text,
    creator: user_id,
    date_created: obs_time,
    voided: 0,
    uuid: SecureRandom.uuid,
    comments: PREFIX
  }
end

def patient_birthdate(today, index)
  age = 18 + (index % 22)
  Date.new(today.year - age, 1, 1)
end

def ensure_patient(group, index, user_id, location_id, today)
  identifier_type = dummy_identifier_type.patient_identifier_type_id
  identifier = format('%<prefix>s-%<group>s-%<index>03d', prefix: PREFIX, group: group, index: index)
  existing = PatientIdentifier.unscoped.find_by(identifier_type: identifier_type, identifier: identifier)
  return existing.patient_id if existing

  person = Person.create!(
    gender: 'F',
    birthdate: patient_birthdate(today, index),
    birthdate_estimated: 0,
    dead: 0,
    creator: user_id,
    changed_by: user_id,
    uuid: SecureRandom.uuid
  )

  Patient.create!(
    patient_id: person.person_id,
    creator: user_id,
    changed_by: user_id
  )

  PersonName.create!(
    person_id: person.person_id,
    preferred: 1,
    given_name: GROUPS.fetch(group).fetch(:given_name),
    family_name: 'Dashboard',
    creator: user_id,
    changed_by: user_id,
    uuid: SecureRandom.uuid
  )

  PatientIdentifier.create!(
    patient_id: person.person_id,
    identifier: identifier,
    identifier_type: identifier_type,
    preferred: 1,
    location_id: location_id,
    creator: user_id,
    uuid: SecureRandom.uuid
  )

  person.person_id
end

def ensure_program_rows(patient_ids_by_group, user_id, location_id, now)
  rows = []
  patient_ids_by_group.each do |group, patient_ids|
    program_id = GROUPS.fetch(group).fetch(:program_id)
    existing = PatientProgram.unscoped.where(patient_id: patient_ids, program_id: program_id).pluck(:patient_id).to_set
    patient_ids.each do |patient_id|
      next if existing.include?(patient_id)

      rows << {
        patient_id: patient_id,
        program_id: program_id,
        date_enrolled: now,
        creator: user_id,
        date_created: now,
        changed_by: user_id,
        date_changed: now,
        voided: 0,
        uuid: SecureRandom.uuid,
        location_id: location_id
      }
    end
  end

  PatientProgram.insert_all!(rows) if rows.any?
  rows.size
end

def ensure_encounters(patient_ids_by_group, user_id, provider_id, location_id, now)
  inserted = 0
  patient_ids_by_group.each do |group, patient_ids|
    config = GROUPS.fetch(group)
    existing = Encounter.unscoped
                        .where(patient_id: patient_ids, program_id: config.fetch(:program_id),
                               encounter_type: config.fetch(:encounter_type), location_id: location_id.to_s)
                        .pluck(:patient_id)
                        .to_set
    rows = []
    patient_ids.each_with_index do |patient_id, index|
      next if existing.include?(patient_id)

      encounter_time = now - (index % 90).minutes
      rows << {
        encounter_type: config.fetch(:encounter_type),
        patient_id: patient_id,
        provider_id: provider_id,
        location_id: location_id.to_s,
        encounter_datetime: encounter_time,
        creator: user_id,
        date_created: encounter_time,
        voided: 0,
        uuid: SecureRandom.uuid,
        changed_by: user_id,
        date_changed: encounter_time,
        program_id: config.fetch(:program_id)
      }
    end
    Encounter.insert_all!(rows) if rows.any?
    inserted += rows.size
  end
  inserted
end

def encounters_by_group(patient_ids_by_group, location_id)
  patient_ids_by_group.to_h do |group, patient_ids|
    config = GROUPS.fetch(group)
    rows = Encounter.unscoped
                    .where(patient_id: patient_ids, program_id: config.fetch(:program_id),
                           encounter_type: config.fetch(:encounter_type), location_id: location_id.to_s)
                    .order(:encounter_id)
                    .pluck(:patient_id, :encounter_id, :encounter_datetime)
    [group, rows.each_with_object({}) { |(patient_id, encounter_id, encounter_time), memo| memo[patient_id] ||= [encounter_id, encounter_time] }]
  end
end

def add_anc_obs(rows, patient_id, encounter_id, obs_time, idx, user_id, location_id, concepts)
  if idx < 70
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Ultrasound scan status'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Ultrasound scan conducted'), value_text: 'Ultrasound scan conducted')
  end

  if idx < 45
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Number of previous anc contacts'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id, value_numeric: 4 + (idx % 3))
  end

  if idx < 15
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Due to previous C/S?'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Yes'), value_text: 'Yes')
  end

  if idx < 25
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('HIV test'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Positive'), value_text: 'Positive')
  end

  if idx < 10
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Chronic conditions'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('HIV Positive'), value_text: 'HIV Positive')
  end

  if idx < 20
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Is client on ART?'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Yes'), value_text: 'Yes')
  end

  if idx < 80
    result = idx % 10 == 0 ? 'Positive' : 'Negative'
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Syphilis Test Result'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch(result), value_text: result)
  end

  if idx < 75
    result = idx % 12 == 0 ? 'Positive' : 'Negative'
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Hepatitis B'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch(result), value_text: result)
  end

  return unless idx < 65

  rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Insecticide treated net given'),
                  obs_time: obs_time, user_id: user_id, location_id: location_id,
                  value_coded: concepts.fetch('Yes'), value_text: 'Yes')
end

def add_pnc_obs(rows, patient_id, encounter_id, obs_time, idx, user_id, location_id, concepts)
  if idx < 80
    check_value = idx.even? ? 'Up to 48 hrs or before discharge' : '3-7 days'
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Postnatal check period'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch(check_value), value_text: check_value)
  end

  if idx < 70
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Breast feeding'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Breastfed exclusively'), value_text: 'Breastfed exclusively')
  end

  if idx < 20
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Mother HIV Status'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Positive'), value_text: 'positive')
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Mother hiv positive'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Yes'), value_text: 'Yes')
  end

  if idx < 60
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Immunisation given'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('BCG'), value_text: 'BCG')
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Type of immunization the baby received'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('BCG'), value_text: 'BCG')
  end

  if idx < 50
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Immunisation given'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Polio 0'), value_text: 'Polio 0')
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Type of immunization the baby received'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Polio 0'), value_text: 'Polio 0')
  end

  if idx < 30
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Newborn baby complications'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Low birth weight'), value_text: 'Low birth weight')
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Low birth weight'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Yes'), value_text: 'Yes')
  end

  return unless idx < 18

  rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Management given to newborn'),
                  obs_time: obs_time, user_id: user_id, location_id: location_id,
                  value_coded: concepts.fetch('Kangaroo mother care'), value_text: 'Kangaroo mother care')
  rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Prematurity/Kangaroo'),
                  obs_time: obs_time, user_id: user_id, location_id: location_id,
                  value_coded: concepts.fetch('Yes'), value_text: 'Yes')
end

def add_labour_obs(rows, patient_id, encounter_id, obs_time, idx, user_id, location_id, concepts)
  backend_skilled = 'Skilled Health worker ( Nurse/Midwife/Clinician/Medical Doctor)'
  fallback_skilled = 'Skilled health worker (Nurse midwife/community midwife assistant/medical assistant/clinical technician/medical doctor'
  staff_values = idx < 80 ? [backend_skilled, fallback_skilled] : ['Traditional birth attendant']
  staff_values.each do |staff_value|
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Staff conducting delivery'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id, value_text: staff_value)
  end

  place = if idx < 85
            'This facility'
          elsif idx < 95
            'Home'
          else
            'In transit'
          end
  rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Place of delivery'),
                  obs_time: obs_time, user_id: user_id, location_id: location_id,
                  value_coded: concepts.fetch(place), value_text: place)

  if idx < 25
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Mode of delivery'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id,
                    value_coded: concepts.fetch('Caesarean section'), value_text: 'Caesarean section')
  else
    rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Mode of delivery'),
                    obs_time: obs_time, user_id: user_id, location_id: location_id, value_text: 'Spontaneous vaginal delivery')
  end

  complication =
    case idx
    when 0...60 then 'None'
    when 60...70 then 'Postpartum haemorrhage'
    when 70...78 then 'Pre-eclampsia'
    when 78...83 then 'Eclampsia'
    when 83...88 then 'Sepsis'
    when 88...92 then 'Retained placenta'
    when 92...97 then 'Perineal tear'
    else 'Other'
    end
  rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Obstetric complications'),
                  obs_time: obs_time, user_id: user_id, location_id: location_id,
                  value_coded: concepts.fetch(complication), value_text: complication)

  referral_codes = %w[ICU_ADVANCED_MONITORING SURGICAL_INTERVENTION BLOOD_TRANSFUSION SPECIALIST_CONSULTATION]
  return unless idx < 20

  rows << obs_row(patient_id: patient_id, encounter_id: encounter_id, concept_id: concepts.fetch('Referral reasons'),
                  obs_time: obs_time, user_id: user_id, location_id: location_id,
                  value_text: referral_codes[idx % referral_codes.length])
end

def ensure_observations(patient_ids_by_group, encounter_map, user_id, location_id, concepts)
  rows = []
  patient_ids_by_group.each do |group, patient_ids|
    patient_ids.each_with_index do |patient_id, idx|
      encounter_id, encounter_time = encounter_map.fetch(group).fetch(patient_id)
      next if Observation.unscoped.where(encounter_id: encounter_id, comments: PREFIX).exists?

      obs_time = encounter_time
      case group
      when 'ANC'
        add_anc_obs(rows, patient_id, encounter_id, obs_time, idx, user_id, location_id, concepts)
      when 'PNC'
        add_pnc_obs(rows, patient_id, encounter_id, obs_time, idx, user_id, location_id, concepts)
      when 'LABOUR'
        add_labour_obs(rows, patient_id, encounter_id, obs_time, idx, user_id, location_id, concepts)
      end
    end
  end

  rows.each_slice(500) { |slice| Observation.insert_all!(slice) }
  rows.size
end

user = active_seed_user
raise 'No seed user found' unless user

location = Location.unscoped.find_by(location_id: user.location_id) || Location.unscoped.find_by(location_id: 1824) || Location.unscoped.first
raise 'No seed location found' unless location

User.current = user if User.respond_to?(:current=)
Location.current = location if Location.respond_to?(:current=)

provider_id = user.person_id || Person.unscoped.first&.person_id
raise 'No provider person found' unless provider_id

concept_names = [
  'Yes', 'Positive', 'Negative',
  'Ultrasound scan status', 'Ultrasound scan conducted', 'Number of previous anc contacts', 'Due to previous C/S?',
  'HIV test', 'HIV Positive', 'Chronic conditions', 'Is client on ART?', 'Syphilis Test Result', 'Hepatitis B',
  'Insecticide treated net given',
  'Postnatal check period', 'Up to 48 hrs or before discharge', '3-7 days', 'Breast feeding', 'Breastfed exclusively',
  'Mother HIV Status', 'Mother hiv positive', 'Immunisation given', 'Type of immunization the baby received', 'BCG',
  'Polio 0', 'Newborn baby complications', 'Low birth weight', 'Management given to newborn', 'Kangaroo mother care',
  'Prematurity/Kangaroo',
  'Staff conducting delivery', 'Place of delivery', 'This facility', 'Home', 'In transit', 'Mode of delivery',
  'Caesarean section', 'Obstetric complications', 'None', 'Postpartum haemorrhage', 'Pre-eclampsia', 'Eclampsia',
  'Sepsis', 'Retained placenta', 'Perineal tear', 'Other', 'Referral reasons'
]
concepts = load_concepts(concept_names)

now = Time.zone.now
today = Date.current
patient_ids_by_group = {}
created_before = PatientIdentifier.unscoped.where('identifier LIKE ?', "#{PREFIX}%").count

ActiveRecord::Base.transaction do
  GROUPS.each_key do |group|
    patient_ids_by_group[group] = (1..TARGET_PER_MODULE).map do |index|
      ensure_patient(group, index, user.user_id, location.location_id, today)
    end
  end

  @programs_inserted = ensure_program_rows(patient_ids_by_group, user.user_id, location.location_id, now)
  @encounters_inserted = ensure_encounters(patient_ids_by_group, user.user_id, provider_id, location.location_id, now)
  @encounter_map = encounters_by_group(patient_ids_by_group, location.location_id)
  @observations_inserted = ensure_observations(patient_ids_by_group, @encounter_map, user.user_id, location.location_id, concepts)
end

created_after = PatientIdentifier.unscoped.where('identifier LIKE ?', "#{PREFIX}%").count

seed_counts = GROUPS.to_h do |group, config|
  ids = patient_ids_by_group.fetch(group)
  encounter_count = Encounter.unscoped.where(patient_id: ids, program_id: config.fetch(:program_id),
                                             location_id: location.location_id.to_s, voided: 0).distinct.count(:patient_id)
  [group.downcase, { patients: ids.size, dashboard_encounter_patients: encounter_count }]
end

verification = {
  anc: MnhService::Engine.new.anc_stats(12, nil, location_id: location.location_id),
  pnc: MnhService::Engine.new.stats(35, nil, location_id: location.location_id),
  labour: MnhService::Engine.new.stats(36, nil, location_id: location.location_id)
}

puts JSON.pretty_generate(
  seed_prefix: PREFIX,
  user: { user_id: user.user_id, username: user.username },
  location: { location_id: location.location_id, name: location.name },
  seed_patient_identifiers_before: created_before,
  seed_patient_identifiers_after: created_after,
  inserted: {
    patient_identifiers: created_after - created_before,
    patient_programs: @programs_inserted,
    encounters: @encounters_inserted,
    observations: @observations_inserted
  },
  seed_counts: seed_counts,
  dashboard_verification: {
    anc_total_active_pregnancies: verification.fetch(:anc).fetch(:new_and_continuing_anc_clients),
    pnc_total_postnatal_mothers: verification.fetch(:pnc).fetch(:total_postnatal_mothers),
    labour_total_mothers: verification.fetch(:labour).fetch(:total_labour_mothers),
    anc_percentages: verification.fetch(:anc).slice(
      :percentage_women_ultrasound_scanning,
      :percentage_women_4_plus_anc_contacts,
      :percentage_clients_previous_uterine_scars,
      :percentage_anc_hiv_positive_on_art,
      :percentage_women_tested_syphilis_during_anc,
      :percentage_women_tested_hepatitis_b_during_anc,
      :percentage_women_received_itn_during_anc
    ),
    pnc_percentages: verification.fetch(:pnc).slice(
      :percentage_postnatal_mothers_hiv_positive,
      :percentage_postnatal_mothers_checked_within_seven_days,
      :percentage_women_counselled_exclusive_breastfeeding,
      :percentage_babies_receiving_bcg,
      :percentage_babies_receiving_polio_0
    ),
    labour_percentages: verification.fetch(:labour).slice(
      :percentage_delivered_by_skilled_attendants,
      :percentage_delivered_at_this_facility,
      :percentage_caesarean_section,
      :obstetric_complication_none_percentage,
      :obstetric_complication_postpartum_haemorrhage_percentage,
      :obstetric_complication_pre_eclampsia_percentage,
      :obstetric_complication_eclampsia_percentage,
      :obstetric_complication_sepsis_percentage,
      :obstetric_complication_retained_placenta_percentage,
      :obstetric_complication_perineal_tear_percentage
    )
  }
)
