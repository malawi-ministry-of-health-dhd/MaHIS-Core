# frozen_string_literal: true

class EncounterService
  def self.recent_encounter(encounter_type_name:, patient_id:, date: nil,
                            start_date: nil, program_id: nil)
    start_date ||= Date.strptime('1900-01-01')
    date ||= Date.today
    type = EncounterType.find_by(name: encounter_type_name)

    query = Encounter.where(type:, patient_id:)\
                     .where('encounter_datetime BETWEEN ? AND ?',
                            start_date.to_date.strftime('%Y-%m-%d 00:00:00'),
                            date.to_date.strftime('%Y-%m-%d 23:59:59'))
    query = query.where(program_id:) if program_id
    query.order(encounter_datetime: :desc).first
  end

  def create(type:, patient:, program:, encounter_datetime: nil, provider: nil, location_id: nil, visit: nil)
    encounter_datetime ||= Time.now
    provider ||= User.current.person
    visit ||= open_visit_for_program(patient, program)
    
    # TODO To be refactored in future
    unless program.program_id.to_i == Program.find_by_name('IMMUNIZATION PROGRAM').program_id.to_i
      encounter = find_encounter(type:, patient:, provider:,
                                encounter_datetime:, program:)
      if type.id == EncounterType.find_by(name: 'LAB ORDERS')&.id
        PatientProgramService.new.create(patient:, program: Program.find_by(name: 'Laboratory program'),
                                        date_enrolled: encounter_datetime,location_id: location_id, user: provider )
      end
      return encounter if encounter
    end
    Encounter.create(
      type:, patient:, provider:,
      encounter_datetime:, program:,
      visit:,
      location_id: location_id || User.current.location_id
    )
  end

  def update(encounter, program:, patient: nil, type: nil, encounter_datetime: nil,
             provider: nil)
    updates = {
      patient:, type:, provider:,
      program:, encounter_datetime:
    }
    updates = updates.keep_if { |_, v| !v.nil? }

    encounter.update(updates)
    encounter
  end

  # The patient's open visit for THIS programme.
  #
  # This used to take any open visit (`Visit.find_by(patient_id:, date_stopped: nil)`),
  # which files an encounter under whichever visit the database happened to
  # return first — in practice the oldest still-open one. A patient with a stale
  # open OPD visit therefore had their AETC encounters recorded against OPD, so
  # anything grouping a record by visit mixed the two programmes together.
  #
  # Programmes that do not open visits get no visit at all rather than borrowing
  # another programme's.
  def open_visit_for_program(patient, program)
    return nil if patient.nil? || program.nil?

    Visit.where(patient_id: patient.patient_id, program_id: program.program_id, date_stopped: nil, voided: 0)
         .order(date_started: :desc, visit_id: :desc)
         .first
  end

  def find_encounter(type:, patient:, encounter_datetime:, provider:, program:)
    Encounter.where(type:, patient:, program:)\
             .where('encounter_datetime BETWEEN ? AND ?',
                    *TimeUtils.day_bounds(encounter_datetime))\
             .order(encounter_datetime: :desc)
             .first
  end

  def void(encounter, reason)
    encounter.void(reason)
  end
end
