# frozen_string_literal: true

module MnhService
  class AncStatsQueries
    include ModelUtils
    include MnhService::LocationScope

    LOGGER = Rails.logger
    ANC_ENROLLMENT_ENCOUNTER_TYPE_ID = 237
    MIN_ANC_CONTACTS_FOR_4_PLUS = 4

    def initialize(program_id = nil, location_id: nil)
      @program_id = program_id
      @location_id = location_id
    end

    def stats_hash(_date = nil)
      {
        new_and_continuing_anc_clients: new_and_continuing_anc_clients,
        women_with_ultrasound_scanning: women_with_ultrasound_scanning,
        proportion_women_ultrasound_scanning: proportion_women_ultrasound_scanning,
        percentage_women_ultrasound_scanning: percentage_women_ultrasound_scanning,
        women_with_4_plus_anc_contacts: women_with_4_plus_anc_contacts,
        percentage_women_4_plus_anc_contacts: percentage_women_4_plus_anc_contacts,
        clients_with_previous_uterine_scars: clients_with_previous_uterine_scars,
        percentage_clients_previous_uterine_scars: percentage_clients_previous_uterine_scars,
        anc_hiv_positive_clients: anc_hiv_positive_clients,
        anc_hiv_positive_on_art: anc_hiv_positive_on_art,
        percentage_anc_hiv_positive_on_art: percentage_anc_hiv_positive_on_art,
        women_tested_syphilis_during_anc: women_tested_syphilis_during_anc,
        percentage_women_tested_syphilis_during_anc: percentage_women_tested_syphilis_during_anc,
        women_tested_hepatitis_b_during_anc: women_tested_hepatitis_b_during_anc,
        percentage_women_tested_hepatitis_b_during_anc: percentage_women_tested_hepatitis_b_during_anc,
        women_received_itn_during_anc: women_received_itn_during_anc,
        percentage_women_received_itn_during_anc: percentage_women_received_itn_during_anc
      }
    end

    def new_and_continuing_anc_clients
      return 0 if anc_program_id.nil?

      @new_and_continuing_anc_clients ||= (
        anc_enrollment_encounter_type_id.present? ? count_by_anc_enrollment_encounter : count_by_patient_program
      )
    end

    def women_with_ultrasound_scanning
      return 0 if anc_program_id.nil?

      @women_with_ultrasound_scanning ||= count_women_with_ultrasound_scan
    end

    def proportion_women_ultrasound_scanning
      percentage_ratio(women_with_ultrasound_scanning, new_and_continuing_anc_clients, 4)
    end

    def percentage_women_ultrasound_scanning
      percentage_of(women_with_ultrasound_scanning, new_and_continuing_anc_clients)
    end

    def women_with_4_plus_anc_contacts
      return 0 if anc_program_id.nil?

      @women_with_4_plus_anc_contacts ||= count_women_with_4_plus_anc_contacts
    end

    def percentage_women_4_plus_anc_contacts
      percentage_of(women_with_4_plus_anc_contacts, new_and_continuing_anc_clients)
    end

    def clients_with_previous_uterine_scars
      return 0 if anc_program_id.nil?

      @clients_with_previous_uterine_scars ||= count_clients_with_previous_uterine_scars
    end

    def percentage_clients_previous_uterine_scars
      percentage_of(clients_with_previous_uterine_scars, new_and_continuing_anc_clients)
    end

    def anc_hiv_positive_clients
      return 0 if anc_program_id.nil?

      @anc_hiv_positive_clients ||= hiv_positive_person_ids.size
    end

    def anc_hiv_positive_on_art
      return 0 if anc_program_id.nil?

      @anc_hiv_positive_on_art ||= count_anc_hiv_positive_and_on_art
    end

    def percentage_anc_hiv_positive_on_art
      percentage_of(anc_hiv_positive_on_art, new_and_continuing_anc_clients)
    end

    def women_tested_syphilis_during_anc
      return 0 if anc_program_id.nil?

      @women_tested_syphilis_during_anc ||= count_anc_clients_with_lab_result('Syphilis Test Result')
    end

    def percentage_women_tested_syphilis_during_anc
      percentage_of(women_tested_syphilis_during_anc, new_and_continuing_anc_clients)
    end

    def women_tested_hepatitis_b_during_anc
      return 0 if anc_program_id.nil?

      @women_tested_hepatitis_b_during_anc ||= count_anc_clients_with_lab_result('Hepatitis B')
    end

    def percentage_women_tested_hepatitis_b_during_anc
      percentage_of(women_tested_hepatitis_b_during_anc, new_and_continuing_anc_clients)
    end

    def women_received_itn_during_anc
      return 0 if anc_program_id.nil?

      @women_received_itn_during_anc ||= count_clients_with_text_or_coded_value('Insecticide treated net given', 'Yes')
    end

    def percentage_women_received_itn_during_anc
      percentage_of(women_received_itn_during_anc, new_and_continuing_anc_clients)
    end

    private

    def percentage_of(count, total)
      total.to_i.zero? ? 0.0 : (count.to_f / total * 100).round(2)
    end

    def percentage_ratio(count, total, decimals = 4)
      total.to_i.zero? ? 0.0 : (count.to_f / total).round(decimals)
    end

    def anc_program_id
      @anc_program_id ||= @program_id.presence || Program.unscoped.find_by(name: 'ANC PROGRAM')&.id
    end

    def anc_enrollment_encounter_type_id
      @anc_enrollment_encounter_type_id ||= ANC_ENROLLMENT_ENCOUNTER_TYPE_ID
    end

    def concept_id_for(name)
      @concept_ids_by_name ||= {}
      @concept_ids_by_name[name] ||= ConceptName.unscoped.find_by(name: name)&.concept_id
    end

    def concept_ids_for(*names)
      names.flatten.filter_map { |name| concept_id_for(name) }.uniq
    end

    def yes_concept_id
      @yes_concept_id ||= concept_id_for('Yes')
    end

    def positive_concept_ids
      @positive_concept_ids ||= concept_ids_for('Positive', 'hiv positive')
    end

    def anc_encounter_scope
      scoped_observations_for(anc_program_id)
    end

    def count_by_anc_enrollment_encounter
      scoped_encounters_for(anc_program_id)
        .where(encounter_type: anc_enrollment_encounter_type_id)
        .distinct
        .count(:patient_id)
    end

    def count_by_patient_program
      scope = PatientProgram.unscoped.where(program_id: anc_program_id, voided: 0)
      scope = scope.where(location_filter) if resolved_location_id.present?
      scope.count(:patient_id)
    end

    def count_women_with_ultrasound_scan
      count_clients_with_text_or_coded_value('Ultrasound scan status', 'Ultrasound scan conducted')
    end

    def count_women_with_4_plus_anc_contacts
      previous_contacts_id = concept_id_for('Number of previous anc contacts')
      return 0 if previous_contacts_id.nil?

      scope = anc_encounter_scope.where(concept_id: previous_contacts_id)
      sql = scope
            .select('obs.person_id')
            .group('obs.person_id')
            .having(
              'MAX(COALESCE(obs.value_numeric, CAST(NULLIF(TRIM(obs.value_text), \'\') AS UNSIGNED), 0)) >= ?',
              MIN_ANC_CONTACTS_FOR_4_PLUS
            )
            .to_sql
      result = Observation.connection.select_one("SELECT COUNT(*) AS cnt FROM (#{sql}) t")
      result ? result['cnt'].to_i : 0
    end

    def count_clients_with_previous_uterine_scars
      count_clients_with_text_or_coded_value('Due to previous C/S?', 'Yes')
    end

    def count_anc_hiv_positive_and_on_art
      hiv_positive_ids = hiv_positive_person_ids
      on_art_concept_id = concept_id_for('Is client on ART?')
      return 0 if on_art_concept_id.nil? || hiv_positive_ids.empty?

      scope = anc_encounter_scope.where(person_id: hiv_positive_ids, concept_id: on_art_concept_id)
      if yes_concept_id.present?
        scope = scope.where('obs.value_text = ? OR obs.value_coded = ?', 'Yes', yes_concept_id)
      else
        scope = scope.where(value_text: 'Yes')
      end
      scope.distinct.count(:person_id)
    end

    def count_anc_clients_with_lab_result(concept_name, positive_only: false)
      concept_id = concept_id_for(concept_name)
      return 0 if concept_id.nil?

      scope = anc_encounter_scope.where(concept_id: concept_id)
      if positive_only
        return 0 if positive_concept_ids.empty?

        scope = scope.where('obs.value_text = ? OR obs.value_coded IN (?)', 'Positive', positive_concept_ids)
      else
        result_ids = concept_ids_for('Positive', 'Negative')
        if result_ids.any?
          scope = scope.where('obs.value_text IN (?) OR obs.value_coded IN (?)', %w[Positive Negative], result_ids)
        else
          scope = scope.where(value_text: %w[Positive Negative])
        end
      end
      scope.distinct.count(:person_id)
    end

    def hiv_positive_person_ids
      @hiv_positive_person_ids ||= begin
        scopes = []

        hiv_test_id = concept_id_for('HIV Test')
        if hiv_test_id.present? && positive_concept_ids.any?
          scopes << anc_encounter_scope
                    .where(concept_id: hiv_test_id)
                    .where('obs.value_text = ? OR obs.value_coded IN (?)', 'Positive', positive_concept_ids)
                    .distinct
                    .pluck(:person_id)
        end

        hiv_status_id = concept_id_for('HIV status')
        if hiv_status_id.present? && positive_concept_ids.any?
          scopes << anc_encounter_scope
                    .where(concept_id: hiv_status_id)
                    .where('obs.value_text = ? OR obs.value_coded IN (?)', 'hiv positive', positive_concept_ids)
                    .distinct
                    .pluck(:person_id)
        end

        chronic_conditions_id = concept_id_for('chronic conditions')
        if chronic_conditions_id.present?
          scopes << anc_encounter_scope
                    .where(concept_id: chronic_conditions_id)
                    .where('obs.value_text = ? OR obs.value_coded IN (?)', 'hiv positive', positive_concept_ids.presence || [-1])
                    .distinct
                    .pluck(:person_id)
        end

        scopes.flatten.compact.uniq
      end
    end

    def count_clients_with_text_or_coded_value(concept_name, value_name)
      concept_id = concept_id_for(concept_name)
      return 0 if concept_id.nil?

      value_id = concept_id_for(value_name)
      scope = anc_encounter_scope.where(concept_id: concept_id)
      if value_id.present?
        scope = scope.where('obs.value_text = ? OR obs.value_coded = ?', value_name, value_id)
      else
        scope = scope.where(value_text: value_name)
      end
      scope.distinct.count(:person_id)
    end
  end
end
