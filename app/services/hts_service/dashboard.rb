# frozen_string_literal: true

# HTS Service
module HtsService
  # Dashbiard Class
  class Dashboard
    HTS_PROGRAM_ID = 38
    HIV_PROGRAM_ID = 1
    DEFAULT_HTS_ORDER_TYPE_ID = 13
    HTS_ORDER_TYPE_NAME = 'hts lab'
    APPOINTMENT_ENCOUNTER_NAME = 'appointment'
    APPOINTMENT_DATE_CONCEPT_NAME = 'Appointment date'
    LEGACY_REFERRAL_CONCEPT_NAME = 'Referrals ordered'
    ART_REFERRAL_FALLBACK_NAME = 'ART'
    REFER_TO_OTHER_HOSPITAL_CONCEPT_ID = 50_784
    HTS_TESTING_ENCOUNTER_NAMES = ['hiv testing', 'confirmatory hiv testing', 'testing'].freeze

    def self.daily_statistics(start_date, _end_date)
      art = Observation.joins('INNER JOIN concept_name ON concept_name.concept_id = obs.concept_id')
                       .joins('INNER JOIN encounter ON encounter.encounter_id = obs.encounter_id')
                       .where(obs: { value_text: 'ART' }, encounter: { program_id: HTS_PROGRAM_ID }, concept_name: { name: 'Referrals ordered' })
                       .where('obs_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(start_date))
                       .count

      booked = Observation.joins('INNER JOIN concept_name ON concept_name.concept_id = obs.concept_id')
                          .joins('INNER JOIN encounter ON encounter.encounter_id = obs.encounter_id')
                          .where(encounter: { program_id: HTS_PROGRAM_ID }, concept_name: { name: 'ART visit' })
                          .where('obs.value_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(start_date))
                          .count

      tested = Observation.joins('INNER JOIN concept_name ON concept_name.concept_id = obs.concept_id')
                          .joins('INNER JOIN encounter ON encounter.encounter_id = obs.encounter_id')
                          .where(encounter: { program_id: HTS_PROGRAM_ID }, concept_name: { name: 'ART visit' }, obs: { value_datetime: start_date })
                          .where('obs_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(start_date))
                          .count

      [{
        hts_registered: PatientProgram.where(program_id: HTS_PROGRAM_ID).count,
        enrolled_on_art: art,
        booked_appointments: booked,
        tested_appointments: tested
      }]
    end

    def self.dashboard_stats(filters)
      filters = filters.to_h.symbolize_keys
      dashboard_date = parse_dashboard_date(filters[:date]) || Date.current
      total_client_ids = total_client_patient_ids
      tested_today_ids = clients_tested_on_patient_ids(dashboard_date, filters[:order_type_id])
      referred_to_art_ids = clients_referred_to_art_patient_ids(dashboard_date)
      scheduled_today_ids = visits_scheduled_on_patient_ids(dashboard_date)

      {
        total_clients: total_client_ids.length,
        total_clients_patients: build_patient_rows(total_client_ids),
        clients_with_conclusive_results: clients_with_conclusive_results,
        clients_tested_today: tested_today_ids.length,
        clients_tested_today_patients: build_patient_rows(tested_today_ids),
        clients_referred_to_ART: referred_to_art_ids.length,
        clients_referred_to_ART_patients: build_patient_rows(referred_to_art_ids),
        visit_scheduled_today: scheduled_today_ids.length,
        visit_scheduled_today_patients: build_patient_rows(scheduled_today_ids),
        patient_data: find_orders(filters)
      }
    end

    def self.find_orders(filters)
      filters = filters.to_h.symbolize_keys
      date = parse_dashboard_date(filters.delete(:date))
      order_type_ids = resolve_order_type_ids(filters.delete(:order_type_id))

      query = <<-SQL
        SELECT DISTINCT
          p.person_id AS patient_id,
          CONCAT_WS(' ', pn.given_name, pn.middle_name, pn.family_name) AS patient_name,
          TIMESTAMPDIFF(YEAR, p.birthdate, CURDATE()) AS patient_age,
          p.gender AS patient_gender,
          COUNT(DISTINCT lo.order_id) AS total_orders,
          MAX(lo.start_date) AS most_recent_order_date,
          COUNT(DISTINCT CASE WHEN orders_without_results.order_id IS NOT NULL THEN lo.order_id END) AS orders_without_results,

          GROUP_CONCAT(DISTINCT CASE WHEN orders_without_results.order_id IS NOT NULL THEN prog.program_id END ORDER BY prog.program_id SEPARATOR ', ') AS program_ids,
          GROUP_CONCAT(DISTINCT CASE WHEN orders_without_results.order_id IS NOT NULL THEN prog.name END ORDER BY prog.name SEPARATOR ', ') AS program_names

        FROM orders lo
        INNER JOIN person p ON p.person_id = lo.patient_id AND p.voided = 0
        INNER JOIN order_type ot ON ot.order_type_id = lo.order_type_id AND ot.retired = 0
        LEFT JOIN person_name pn ON pn.person_id = p.person_id AND pn.voided = 0
        LEFT JOIN encounter e ON e.encounter_id = lo.encounter_id AND e.voided = 0
        LEFT JOIN program prog ON prog.program_id = e.program_id AND prog.retired = 0
        LEFT JOIN (
          SELECT DISTINCT o.order_id
          FROM orders o
          LEFT JOIN obs test_obs ON test_obs.order_id = o.order_id AND test_obs.voided = 0
          LEFT JOIN obs result_obs ON result_obs.obs_group_id = test_obs.obs_id AND result_obs.voided = 0
          WHERE o.voided = 0
          GROUP BY o.order_id
          HAVING COUNT(result_obs.obs_id) = 0
        ) AS orders_without_results ON orders_without_results.order_id = lo.order_id
        WHERE lo.voided = 0
          AND lo.order_type_id IN (?)
      SQL

      where_conditions = []
      bind_values = [order_type_ids]

      if filters[:patient_id]
        where_conditions << 'p.person_id = ?'
        bind_values << filters[:patient_id]
      end

      if filters[:accession_number]
        where_conditions << 'lo.accession_number = ?'
        bind_values << filters[:accession_number]
      end

      query += " AND #{where_conditions.join(' AND ')}" unless where_conditions.empty?

      query += <<-SQL
        GROUP BY p.person_id, pn.given_name, pn.middle_name, pn.family_name, p.birthdate, p.gender
        HAVING COUNT(DISTINCT CASE WHEN orders_without_results.order_id IS NOT NULL THEN lo.order_id END) > 0
      SQL

      if date
        query += ' AND DATE(MAX(lo.start_date)) = ?'
        bind_values << date
      end

      query += ' ORDER BY most_recent_order_date DESC'

      results = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.send(:sanitize_sql_array, [query] + bind_values)
      )

      results.map do |row|
        ActiveSupport::HashWithIndifferentAccess.new(
          {
            patient_id: row['patient_id'],
            patient_name: row['patient_name'],
            patient_age: row['patient_age'],
            patient_gender: row['patient_gender'],
            total_orders: row['total_orders'],
            most_recent_order_date: row['most_recent_order_date'],
            orders_without_results: row['orders_without_results'],
            program_ids: row['program_ids'],
            program_names: row['program_names']
          }
        )
      end
    end

    def self.clients_with_conclusive_results
      concepts = {
        9774 => 'Yes',
        223 => 'Positive',
        10_052 => 'Positive',
        10_051 => 'Positive'
      }

      Observation
        .where(concepts.map { |concept_id, value| "(concept_id = #{concept_id} AND value_text = '#{value}')" }.join(' OR '))
        .distinct
        .count(:person_id)
    end

    def self.clients_referred_to_art(dashboard_date)
      clients_referred_to_art_patient_ids(dashboard_date).length
    end

    def self.clients_referred_to_art_patient_ids(dashboard_date)
      Observation
        .joins('INNER JOIN encounter ON encounter.encounter_id = obs.encounter_id AND encounter.voided = 0')
        .where(encounter: { program_id: HTS_PROGRAM_ID })
        .where('obs.obs_datetime BETWEEN ? AND ?', *TimeUtils.day_bounds(dashboard_date))
        .where(
          '(obs.concept_id = :referral_concept_id AND obs.value_numeric IN (:art_program_ids)) OR ' \
          '(obs.concept_id IN (:legacy_referral_concept_ids) AND UPPER(obs.value_text) IN (:art_program_names))',
          referral_concept_id: REFER_TO_OTHER_HOSPITAL_CONCEPT_ID,
          art_program_ids: art_program_ids,
          legacy_referral_concept_ids: referral_concept_ids,
          art_program_names: art_program_names
        )
        .distinct
        .pluck(:person_id)
        .compact
    end

    def self.visits_scheduled_on(dashboard_date)
      visits_scheduled_on_patient_ids(dashboard_date).length
    end

    def self.visits_scheduled_on_patient_ids(dashboard_date)
      Observation
        .joins('INNER JOIN encounter ON encounter.encounter_id = obs.encounter_id AND encounter.voided = 0')
        .where(
          encounter: {
            program_id: HTS_PROGRAM_ID,
            encounter_type: appointment_encounter_type_ids
          },
          concept_id: appointment_date_concept_ids,
          value_datetime: dashboard_date.beginning_of_day..dashboard_date.end_of_day
        )
        .distinct
        .pluck(:person_id)
        .compact
    end

    def self.clients_tested_on(dashboard_date, raw_order_type_id = nil)
      clients_tested_on_patient_ids(dashboard_date, raw_order_type_id).length
    end

    def self.clients_tested_on_patient_ids(dashboard_date, raw_order_type_id = nil)
      Order
        .joins('INNER JOIN encounter e ON e.encounter_id = orders.encounter_id AND e.voided = 0')
        .where(
          voided: 0,
          order_type_id: resolve_order_type_ids(raw_order_type_id),
          start_date: dashboard_date.beginning_of_day..dashboard_date.end_of_day
        )
        .where('e.program_id = ?', HTS_PROGRAM_ID)
        .distinct
        .pluck(:patient_id)
        .compact
    end

    def self.total_client_patient_ids
      Encounter.where(program_id: HTS_PROGRAM_ID).distinct.pluck(:patient_id).compact
    end

    def self.build_patient_rows(patient_ids)
      normalized_ids = Array(patient_ids).map(&:to_i).uniq.reject(&:zero?)
      return [] if normalized_ids.empty?

      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.send(
          :sanitize_sql_array,
          [<<-SQL, normalized_ids]
            SELECT
              p.person_id AS patient_id,
              CONCAT_WS(
                ' ',
                MAX(COALESCE(pn.given_name, '')),
                MAX(COALESCE(pn.middle_name, '')),
                MAX(COALESCE(pn.family_name, ''))
              ) AS patient_name,
              TIMESTAMPDIFF(YEAR, p.birthdate, CURDATE()) AS patient_age,
              p.gender AS patient_gender
            FROM person p
            LEFT JOIN person_name pn ON pn.person_id = p.person_id AND pn.voided = 0
            WHERE p.voided = 0
              AND p.person_id IN (?)
            GROUP BY p.person_id, p.birthdate, p.gender
            ORDER BY patient_name ASC
          SQL
        )
      )

      rows.map do |row|
        ActiveSupport::HashWithIndifferentAccess.new(
          patient_id: row['patient_id'],
          patient_name: row['patient_name'],
          patient_age: row['patient_age'],
          patient_gender: row['patient_gender']
        )
      end
    end

    def self.appointment_encounter_type_ids
      EncounterType.unscoped.where('LOWER(name) = ?', APPOINTMENT_ENCOUNTER_NAME).pluck(:encounter_type_id).presence || [7]
    end

    def self.appointment_date_concept_ids
      ConceptName.unscoped.where(name: APPOINTMENT_DATE_CONCEPT_NAME).pluck(:concept_id)
    end

    def self.referral_concept_ids
      ConceptName.unscoped.where(name: LEGACY_REFERRAL_CONCEPT_NAME).pluck(:concept_id)
    end

    def self.art_program_ids
      Program.unscoped.where('LOWER(name) IN (?)', ['hiv program', 'art program']).pluck(:program_id).presence || [HIV_PROGRAM_ID]
    end

    def self.art_program_names
      (Program.unscoped.where(program_id: art_program_ids).pluck(:name) + [ART_REFERRAL_FALLBACK_NAME]).map(&:upcase).uniq
    end

    def self.hts_testing_encounter_type_ids
      EncounterType.unscoped.where('LOWER(name) IN (?)', HTS_TESTING_ENCOUNTER_NAMES).pluck(:encounter_type_id).presence || [133, 150]
    end

    def self.resolve_order_type_ids(raw_order_type_id)
      hts_order_type_ids = OrderType.unscoped.where('LOWER(name) = ?', HTS_ORDER_TYPE_NAME).pluck(:order_type_id)
      requested_order_type_id = raw_order_type_id.to_i if raw_order_type_id.present?

      if requested_order_type_id&.positive?
        requested_order_type = OrderType.unscoped.find_by(order_type_id: requested_order_type_id)
        return hts_order_type_ids.presence || [requested_order_type_id] if requested_order_type&.name&.casecmp(HTS_ORDER_TYPE_NAME)&.zero?

        return [requested_order_type_id]
      end

      hts_order_type_ids.presence || [DEFAULT_HTS_ORDER_TYPE_ID]
    end

    def self.parse_dashboard_date(raw_date)
      return raw_date if raw_date.is_a?(Date)
      return if raw_date.blank?

      Date.parse(raw_date.to_s)
    rescue ArgumentError
      nil
    end

  end
end
