# frozen_string_literal: true

module MnhService
  class LabourStatsQueries
    include ModelUtils
    include MnhService::LocationScope

    LOGGER = Rails.logger
    SKILLED_ATTENDANT_VALUE = 'Skilled Health worker ( Nurse/Midwife/Clinician/Medical Doctor)'

    OBSTETRIC_COMPLICATION_CONDITIONS = [
      'None',
      'Postpartum haemorrhage',
      'Pre-Eclampsia',
      'Eclampsia',
      'Sepsis',
      'Retained placenta',
      'Perineal tear',
      'Other'
    ].freeze

    REFERRAL_REASON_OPTIONS = [
      { label: 'ICU advanced monitoring', value_text: 'ICU_ADVANCED_MONITORING' },
      { label: 'Surgical intervention', value_text: 'SURGICAL_INTERVENTION' },
      { label: 'Blood transfusion', value_text: 'BLOOD_TRANSFUSION' },
      { label: 'Specialist consultation', value_text: 'SPECIALIST_CONSULTATION' }
    ].freeze

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
      base = {
        total_labour_mothers: total_labour_mothers,
        mothers_delivered_by_skilled_attendant: mothers_delivered_by_skilled_attendant,
        total_deliveries_with_staff_recorded: total_deliveries_with_staff_recorded,
        percentage_delivered_by_skilled_attendants: percentage_delivered_by_skilled_attendants,
        clients_delivered_at_home_or_in_transit: clients_delivered_at_home_or_in_transit,
        clients_delivered_at_this_facility: clients_delivered_at_this_facility,
        total_deliveries_with_place_recorded: total_deliveries_with_place_recorded,
        percentage_delivered_at_this_facility: percentage_delivered_at_this_facility,
        total_clients_with_obstetric_complications_recorded: total_clients_with_obstetric_complications_recorded,
        caesarean_section_count: caesarean_section_count,
        total_deliveries_with_mode_recorded: total_deliveries_with_mode_recorded,
        percentage_caesarean_section: percentage_caesarean_section,
        referral_by_condition: referral_by_condition
      }
      counts = obstetric_complication_counts.transform_keys { |k| "obstetric_complication_#{k}_count".to_sym }
      percentages = obstetric_complication_percentages.transform_keys { |k| "obstetric_complication_#{k}_percentage".to_sym }
      base.merge(counts).merge(percentages)
    end

    def mothers_delivered_by_skilled_attendant
      return 0 if labour_program_id.nil?

      @mothers_delivered_by_skilled_attendant ||= count_deliveries_with_skilled_attendant
    end

    def total_deliveries_with_staff_recorded
      return 0 if labour_program_id.nil?

      @total_deliveries_with_staff_recorded ||= count_total_deliveries_with_staff_recorded
    end

    def percentage_delivered_by_skilled_attendants
      percentage_of(mothers_delivered_by_skilled_attendant, total_labour_mothers)
    end

    def clients_delivered_at_home_or_in_transit
      return 0 if labour_program_id.nil?

      @clients_delivered_at_home_or_in_transit ||= count_clients_delivered_at_home_or_in_transit
    end

    def clients_delivered_at_this_facility
      return 0 if labour_program_id.nil?

      @clients_delivered_at_this_facility ||= count_clients_delivered_at_this_facility
    end

    def total_deliveries_with_place_recorded
      return 0 if labour_program_id.nil?

      @total_deliveries_with_place_recorded ||= count_total_deliveries_with_place_recorded
    end

    def percentage_delivered_at_this_facility
      percentage_of(clients_delivered_at_this_facility, total_labour_mothers)
    end

    def total_clients_with_obstetric_complications_recorded
      return 0 if labour_program_id.nil?

      @total_clients_with_obstetric_complications_recorded ||= count_total_with_obstetric_complications_recorded
    end

    def obstetric_complication_counts
      return {} if labour_program_id.nil?

      @obstetric_complication_counts ||= count_obstetric_complications_by_condition
    end

    def obstetric_complication_percentages
      total = total_labour_mothers
      return {} if total.zero?

      obstetric_complication_counts.transform_values { |count| percentage_of(count, total) }
    end

    def caesarean_section_count
      return 0 if labour_program_id.nil?

      @caesarean_section_count ||= count_caesarean_section
    end

    def total_deliveries_with_mode_recorded
      return 0 if labour_program_id.nil?

      @total_deliveries_with_mode_recorded ||= count_total_deliveries_with_mode_recorded
    end

    def percentage_caesarean_section
      percentage_of(caesarean_section_count, total_labour_mothers)
    end

    def total_labour_mothers
      return 0 if labour_program_id.nil?

      @total_labour_mothers ||= count_total_labour_mothers
    end

    def referral_by_condition
      @referral_by_condition ||= build_referral_by_condition
    end

    private

    def parse_date(value)
      return nil if value.blank?
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def labour_program_id
      @labour_program_id ||= @program_id.presence ||
                             Program.unscoped.where(Program.arel_table[:name].lower.eq('labour program')).first&.id
    end

    def concept_id_for(name)
      MnhService::ConceptCache.concept_id(name)
    end

    def staff_conducting_delivery_concept_id
      @staff_conducting_delivery_concept_id ||= concept_id_for('Staff conducting delivery')
    end

    def place_of_delivery_concept_id
      @place_of_delivery_concept_id ||= concept_id_for('Place of delivery')
    end

    def home_concept_id
      @home_concept_id ||= concept_id_for('Home')
    end

    def in_transit_concept_id
      @in_transit_concept_id ||= concept_id_for('In transit')
    end

    def this_facility_concept_id
      @this_facility_concept_id ||= concept_id_for('This facility')
    end

    def obstetric_complications_concept_id
      @obstetric_complications_concept_id ||= concept_id_for('Obstetric complications')
    end

    def mode_of_delivery_concept_id
      @mode_of_delivery_concept_id ||= concept_id_for('Mode of delivery')
    end

    def caesarean_section_concept_id
      @caesarean_section_concept_id ||= concept_id_for('Caesarean section')
    end

    def referral_reasons_concept_id
      @referral_reasons_concept_id ||= concept_id_for('referral reasons')
    end

    def condition_key(value)
      value.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_|_\z/, '')
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

    def labour_encounter_scope
      apply_date_scope(scoped_observations_for(labour_program_id))
    end

    def labour_encounters_scope
      apply_date_scope(scoped_encounters_for(labour_program_id), 'encounter_datetime')
    end

    def count_total_labour_mothers
      labour_encounters_scope.distinct.count(:patient_id)
    end

    def percentage_of(count, total)
      total.to_i.zero? ? 0.0 : (count.to_f / total * 100).round(2)
    end

    def count_deliveries_with_skilled_attendant
      return 0 if staff_conducting_delivery_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: staff_conducting_delivery_concept_id)
        .where('obs.value_text = ?', SKILLED_ATTENDANT_VALUE)
        .distinct
        .count(:person_id)
    end

    def count_total_deliveries_with_staff_recorded
      return 0 if staff_conducting_delivery_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: staff_conducting_delivery_concept_id)
        .where('obs.value_text IS NOT NULL AND obs.value_text != ?', '')
        .distinct
        .count(:person_id)
    end

    def count_clients_delivered_at_home_or_in_transit
      return 0 if place_of_delivery_concept_id.nil?
      return 0 if home_concept_id.nil? && in_transit_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: place_of_delivery_concept_id)
        .where('obs.value_coded IN (?)', [home_concept_id, in_transit_concept_id].compact)
        .distinct
        .count(:person_id)
    end

    def count_clients_delivered_at_this_facility
      return 0 if place_of_delivery_concept_id.nil? || this_facility_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: place_of_delivery_concept_id)
        .where('obs.value_coded = ?', this_facility_concept_id)
        .distinct
        .count(:person_id)
    end

    def count_total_deliveries_with_place_recorded
      return 0 if place_of_delivery_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: place_of_delivery_concept_id)
        .where('obs.value_coded IS NOT NULL OR (obs.value_text IS NOT NULL AND obs.value_text != ?)', '')
        .distinct
        .count(:person_id)
    end

    def count_total_with_obstetric_complications_recorded
      return 0 if obstetric_complications_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: obstetric_complications_concept_id)
        .where('obs.value_coded IS NOT NULL OR (obs.value_text IS NOT NULL AND obs.value_text != ?)', '')
        .distinct
        .count(:person_id)
    end

    def count_caesarean_section
      return 0 if mode_of_delivery_concept_id.nil? || caesarean_section_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: mode_of_delivery_concept_id)
        .where('obs.value_coded = ?', caesarean_section_concept_id)
        .distinct
        .count(:person_id)
    end

    def count_total_deliveries_with_mode_recorded
      return 0 if mode_of_delivery_concept_id.nil?

      labour_encounter_scope
        .where(concept_id: mode_of_delivery_concept_id)
        .where('obs.value_coded IS NOT NULL OR (obs.value_text IS NOT NULL AND obs.value_text != ?)', '')
        .distinct
        .count(:person_id)
    end

    def count_obstetric_complications_by_condition
      return {} if obstetric_complications_concept_id.nil?

      OBSTETRIC_COMPLICATION_CONDITIONS.each_with_object({}) do |value, result|
        concept_id = concept_id_for(value)
        next if concept_id.nil?

        result[condition_key(value)] = labour_encounter_scope
                                      .where(concept_id: obstetric_complications_concept_id)
                                      .where('obs.value_coded = ?', concept_id)
                                      .distinct
                                      .count(:person_id)
      end
    end

    def build_referral_by_condition
      return [] if referral_reasons_concept_id.nil?

      total = total_labour_mothers
      REFERRAL_REASON_OPTIONS.map do |option|
        count = labour_encounter_scope
                .where(concept_id: referral_reasons_concept_id)
                .where('obs.value_text = ?', option[:value_text])
                .distinct
                .count(:person_id)
        { label: option[:label], percentage: percentage_of(count, total) }
      end
    end
  end
end
