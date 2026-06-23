# frozen_string_literal: true

module MnhService
  class PncStatsQueries
    include ModelUtils
    include MnhService::LocationScope

    LOGGER = Rails.logger

    def initialize(program_id = nil, date = nil, location_id: nil, start_date: nil, end_date: nil)
      @program_id = program_id
      @location_id = location_id
      if start_date.present? || end_date.present?
        @start_date = parse_date(start_date)
        @end_date   = parse_date(end_date)
      elsif date.present?
        parsed = parse_date(date)
        @start_date = parsed
        @end_date   = parsed
      end
    end

    def stats_hash
      {
        babies_receiving_bcg: babies_receiving_bcg,
        total_babies_with_immunisation_recorded: total_babies_with_immunisation_recorded,
        percentage_babies_receiving_bcg: percentage_babies_receiving_bcg,
        babies_receiving_polio_0: babies_receiving_polio_0,
        percentage_babies_receiving_polio_0: percentage_babies_receiving_polio_0,
        mothers_hiv_positive: mothers_hiv_positive,
        total_postnatal_mothers: total_postnatal_mothers,
        percentage_postnatal_mothers_hiv_positive: percentage_postnatal_mothers_hiv_positive,
        mothers_checked_within_seven_days: mothers_checked_within_seven_days,
        percentage_postnatal_mothers_checked_within_seven_days: percentage_postnatal_mothers_checked_within_seven_days,
        women_counselled_exclusive_breastfeeding: women_counselled_exclusive_breastfeeding,
        percentage_women_counselled_exclusive_breastfeeding: percentage_women_counselled_exclusive_breastfeeding
      }
    end

    def babies_receiving_bcg
      return 0 if pnc_program_id.nil?

      @babies_receiving_bcg ||= count_babies_receiving_bcg
    end

    def total_babies_with_immunisation_recorded
      return 0 if pnc_program_id.nil?

      @total_babies_with_immunisation_recorded ||= count_total_with_immunisation_recorded
    end

    def percentage_babies_receiving_bcg
      percentage_of(babies_receiving_bcg, total_babies_with_immunisation_recorded)
    end

    def babies_receiving_polio_0
      return 0 if pnc_program_id.nil?

      @babies_receiving_polio_0 ||= count_babies_receiving_polio_0
    end

    def percentage_babies_receiving_polio_0
      percentage_of(babies_receiving_polio_0, total_babies_with_immunisation_recorded)
    end

    def mothers_hiv_positive
      return 0 if pnc_program_id.nil?

      @mothers_hiv_positive ||= count_mothers_hiv_positive
    end

    def total_postnatal_mothers
      return 0 if pnc_program_id.nil?

      @total_postnatal_mothers ||= count_total_postnatal_mothers
    end

    def percentage_postnatal_mothers_hiv_positive
      percentage_of(mothers_hiv_positive, total_postnatal_mothers)
    end

    def mothers_checked_within_seven_days
      return 0 if pnc_program_id.nil?

      @mothers_checked_within_seven_days ||= count_mothers_checked_within_seven_days
    end

    def percentage_postnatal_mothers_checked_within_seven_days
      percentage_of(mothers_checked_within_seven_days, total_postnatal_mothers)
    end

    def women_counselled_exclusive_breastfeeding
      return 0 if pnc_program_id.nil?

      @women_counselled_exclusive_breastfeeding ||= count_women_counselled_exclusive_breastfeeding
    end

    def percentage_women_counselled_exclusive_breastfeeding
      percentage_of(women_counselled_exclusive_breastfeeding, total_postnatal_mothers)
    end

    private

    def parse_date(value)
      return nil if value.blank?
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def percentage_of(count, total)
      total.to_i.zero? ? 0.0 : (count.to_f / total * 100).round(2)
    end

    def pnc_program_id
      @pnc_program_id ||= @program_id.presence ||
                          Program.unscoped.where(Program.arel_table[:name].lower.eq('pnc program')).first&.id
    end

    def concept_id_for(name)
      MnhService::ConceptCache.concept_id(name)
    end

    def concept_ids_for(*names)
      names.flatten.filter_map { |n| concept_id_for(n) }.uniq
    end

    def immunisation_given_concept_id
      @immunisation_given_concept_id ||= concept_id_for('Immunisation given')
    end

    # Resolve both 'BCG' and 'bcg' to handle case variation in concept names
    def bcg_concept_ids
      @bcg_concept_ids ||= concept_ids_for('BCG', 'bcg')
    end

    # Resolve 'Polio 0', 'Polio', and 'polio' to handle name variation
    def polio_concept_ids
      @polio_concept_ids ||= concept_ids_for('Polio 0', 'Polio', 'polio')
    end

    def mother_hiv_status_concept_id
      @mother_hiv_status_concept_id ||= concept_id_for('Mother HIV Status')
    end

    def postnatal_check_period_concept_id
      @postnatal_check_period_concept_id ||= concept_id_for('Postnatal check period')
    end

    def three_to_seven_days_concept_id
      @three_to_seven_days_concept_id ||= concept_id_for('3-7 days')
    end

    def up_to_48hrs_concept_id
      @up_to_48hrs_concept_id ||= concept_id_for('Up to 48 hrs or before discharge')
    end

    def breast_feeding_concept_id
      @breast_feeding_concept_id ||= concept_id_for('Breast feeding')
    end

    def breastfed_exclusively_concept_id
      @breastfed_exclusively_concept_id ||= concept_id_for('Breastfed exclusively')
    end

    def apply_date_scope(scope, datetime_column = 'encounter.encounter_datetime')
      if @start_date.present? && @end_date.present?
        scope.where("#{datetime_column} >= ? AND #{datetime_column} <= ?",
                    @start_date.beginning_of_day, @end_date.end_of_day)
      elsif @start_date.present?
        scope.where("#{datetime_column} >= ?", @start_date.beginning_of_day)
      elsif @end_date.present?
        scope.where("#{datetime_column} <= ?", @end_date.end_of_day)
      else
        scope
      end
    end

    def pnc_obs_scope
      apply_date_scope(scoped_observations_for(pnc_program_id))
    end

    def pnc_encounter_scope
      apply_date_scope(scoped_encounters_for(pnc_program_id), 'encounter_datetime')
    end

    def count_babies_receiving_bcg
      return 0 if immunisation_given_concept_id.nil? || bcg_concept_ids.empty?

      pnc_obs_scope
        .where(concept_id: immunisation_given_concept_id)
        .where(value_coded: bcg_concept_ids)
        .distinct
        .count(:person_id)
    end

    def count_babies_receiving_polio_0
      return 0 if immunisation_given_concept_id.nil? || polio_concept_ids.empty?

      pnc_obs_scope
        .where(concept_id: immunisation_given_concept_id)
        .where(value_coded: polio_concept_ids)
        .distinct
        .count(:person_id)
    end

    def count_total_with_immunisation_recorded
      return 0 if immunisation_given_concept_id.nil?

      pnc_obs_scope
        .where(concept_id: immunisation_given_concept_id)
        .where('obs.value_coded IS NOT NULL OR (obs.value_text IS NOT NULL AND obs.value_text != ?)', '')
        .distinct
        .count(:person_id)
    end

    def count_mothers_hiv_positive
      return 0 if mother_hiv_status_concept_id.nil?

      # Frontend saves 'Mother HIV Status' concept with value_text 'positive'
      pnc_obs_scope
        .where(concept_id: mother_hiv_status_concept_id)
        .where('LOWER(obs.value_text) = ?', 'positive')
        .distinct
        .count(:person_id)
    end

    def count_total_postnatal_mothers
      pnc_encounter_scope.distinct.count(:patient_id)
    end

    def count_mothers_checked_within_seven_days
      return 0 if postnatal_check_period_concept_id.nil?

      # Include both 'Up to 48 hrs or before discharge' and '3-7 days' as within-7-days checks
      valid_concept_ids = [three_to_seven_days_concept_id, up_to_48hrs_concept_id].compact
      return 0 if valid_concept_ids.empty?

      pnc_obs_scope
        .where(concept_id: postnatal_check_period_concept_id)
        .where(value_coded: valid_concept_ids)
        .distinct
        .count(:person_id)
    end

    def count_women_counselled_exclusive_breastfeeding
      return 0 if breast_feeding_concept_id.nil? || breastfed_exclusively_concept_id.nil?

      pnc_obs_scope
        .where(concept_id: breast_feeding_concept_id)
        .where(value_coded: breastfed_exclusively_concept_id)
        .distinct
        .count(:person_id)
    end
  end
end
