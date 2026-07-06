# frozen_string_literal: true

module MahisUserImport
  class ActivityDefaults
    OPD_FORM_ACTIVITIES = [
      'Clinical Assessment',
      'Investigations',
      'Diagnosis',
      'Treatment Plan',
      'Next Appointment',
      'Outcome'
    ].freeze

    OPD_WAITING_LISTS = [
      'Waiting for Vitals',
      'Waiting for Consultation',
      'Waiting for Laboratory',
      'Waiting for Dispensation',
      'Waiting for Short Stay',
      'Appointments Today',
      'Total Patients Today'
    ].freeze

    NCD_ACTIVITIES = [
      'Vital Signs',
      'Risk Assessment',
      'Investigations',
      'Diagnosis',
      'Complications Screening',
      'Treatment Plan',
      'Next Appointment'
    ].freeze

    HIV_ACTIVITIES = [
      'HIV first visits',
      'HIV reception visits',
      'Vitals',
      'HIV staging visits',
      'ART adherence',
      'HIV clinic consultations',
      'Prescriptions',
      'Drug Dispensations',
      'Manage Appointments'
    ].freeze

    DEFAULTS = {
      'opdprogram' => {
        'clinician' => {
          opd_activities: OPD_FORM_ACTIVITIES,
          opd_waiting_list: OPD_WAITING_LISTS - ['Waiting for Laboratory', 'Waiting for Dispensation']
        },
        'nurse' => {
          opd_waiting_list: ['Total Patients Today', 'Waiting for Vitals', 'Waiting for Short Stay']
        },
        'pharmacist' => {
          opd_waiting_list: ['Total Patients Today', 'Waiting for Dispensation', 'Waiting for Short Stay']
        },
        'lab' => {
          opd_activities: ['Investigations'],
          opd_waiting_list: ['Total Patients Today', 'Waiting for Laboratory', 'Waiting for Short Stay']
        },
        'registrationclerk' => {
          opd_waiting_list: ['Total Patients Today', 'Waiting for Vitals']
        }
      },
      'ncdprogram' => {
        'clinician' => { ncd_activities: NCD_ACTIVITIES },
        'nurse' => { ncd_activities: NCD_ACTIVITIES },
        'pharmacist' => { ncd_activities: ['Treatment Plan'] },
        'lab' => { ncd_activities: ['Investigations'] },
        'registrationclerk' => {}
      },
      'hivprogram' => {
        'clinician' => { activities: HIV_ACTIVITIES },
        'nurse' => { activities: HIV_ACTIVITIES },
        'provider' => { activities: HIV_ACTIVITIES },
        'pharmacist' => { activities: ['Drug Dispensations'] },
        'lab' => { activities: ['Lab activities'] },
        'registrationclerk' => { activities: ['HIV first visits'] }
      }
    }.freeze

    ACTIVITY_KEYS = %i[activities opd_activities ncd_activities opd_waiting_list].freeze

    def self.apply(attributes)
      new(attributes).apply
    end

    def initialize(attributes)
      @attributes = attributes
    end

    def apply
      defaults = ACTIVITY_KEYS.index_with { [] }

      Array(@attributes[:program_names]).each do |program_name|
        program_defaults = DEFAULTS[normalize_key(program_name)]
        next unless program_defaults

        Array(@attributes[:role_names]).each do |role_name|
          role_defaults = program_defaults[normalize_key(role_name)]
          next unless role_defaults

          role_defaults.each do |key, values|
            defaults[key].concat(values)
          end
        end
      end

      defaults.each do |key, values|
        next if @attributes[key].present?

        @attributes[key] = values.uniq.join(',').presence
      end

      @attributes
    end

    private

    def normalize_key(value)
      I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]/, '')
    end
  end
end
