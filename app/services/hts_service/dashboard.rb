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

    # Lightweight summary for the dashboard initial load: only the counts shown
    # on the cards/header plus the day-bounded "awaiting results" list. The
    # per-card patient lists are fetched lazily (see #dashboard_patients) when a
    # card is clicked, so we never build/ship the unbounded "all HTS clients"
    # list on every load.
    def self.dashboard_stats(filters)
      filters = filters.to_h.symbolize_keys
      dashboard_date = parse_dashboard_date(filters[:date]) || Date.current

      {
        total_clients: total_clients_count,
        clients_with_conclusive_results: clients_with_conclusive_results,
        clients_tested_today: clients_tested_on(dashboard_date, filters[:order_type_id]),
        clients_referred_to_ART: clients_referred_to_art(dashboard_date),
        visit_scheduled_today: visits_scheduled_on(dashboard_date),
        patient_data: find_orders(filters)
      }
    end

    # Paginated + searchable patient rows for a single dashboard card category.
    # Backs the lazy-loaded card modals so even the unbounded "total_clients"
    # list is served one page at a time.
    def self.dashboard_patients(filters)
      filters = filters.to_h.symbolize_keys
      dashboard_date = parse_dashboard_date(filters[:date]) || Date.current
      page = [filters[:page].to_i, 1].max
      per_page = filters[:per_page].to_i
      per_page = 50 if per_page <= 0
      per_page = [per_page, 200].min

      patient_ids =
        case filters[:category].to_s
        when 'total_clients'           then total_client_patient_ids
        when 'clients_tested_today'    then clients_tested_on_patient_ids(dashboard_date, filters[:order_type_id])
        when 'clients_referred_to_ART' then clients_referred_to_art_patient_ids(dashboard_date)
        when 'visit_scheduled_today'   then visits_scheduled_on_patient_ids(dashboard_date)
        else []
        end

      build_patient_rows_paginated(patient_ids, page: page, per_page: per_page, search: filters[:search].to_s.strip)
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
            AND o.order_type_id IN (?)
          GROUP BY o.order_id
          HAVING COUNT(result_obs.obs_id) = 0
        ) AS orders_without_results ON orders_without_results.order_id = lo.order_id
        WHERE lo.voided = 0
          AND lo.order_type_id IN (?)
      SQL

      # First bind feeds the orders_without_results sub-query (which appears
      # first in the SQL text), the second feeds the outer WHERE. Scoping the
      # sub-query to the same order types is result-equivalent (it is only ever
      # joined to HTS orders) but stops it scanning every order/obs in the DB.
      where_conditions = []
      bind_values = [order_type_ids, order_type_ids]

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

    # COUNT(DISTINCT ...) at the DB instead of plucking every id into Ruby just
    # to take .length — the "total clients" set is unbounded and grows forever.
    def self.total_clients_count
      Encounter.where(program_id: HTS_PROGRAM_ID).distinct.count(:patient_id)
    end

    DEFAULT_PATIENT_ROWS_PER_PAGE = 50

    # Returns a single page of patient rows for the given ids, with an optional
    # name search and pagination metadata:
    #   { data: [...], pagination: { current_page:, per_page:, total_count:, total_pages: } }
    def self.build_patient_rows_paginated(patient_ids, page: 1, per_page: DEFAULT_PATIENT_ROWS_PER_PAGE, search: '')
      page = [page.to_i, 1].max
      per_page = per_page.to_i
      per_page = DEFAULT_PATIENT_ROWS_PER_PAGE if per_page <= 0

      normalized_ids = Array(patient_ids).map(&:to_i).uniq.reject(&:zero?)
      return empty_patient_page(page, per_page) if normalized_ids.empty?

      where_sql = +'p.voided = 0 AND p.person_id IN (?)'
      where_binds = [normalized_ids]

      search = search.to_s.strip
      if search.present?
        where_sql << " AND CONCAT_WS(' ', COALESCE(pn.given_name, ''), COALESCE(pn.middle_name, ''), " \
                     "COALESCE(pn.family_name, '')) LIKE ?"
        where_binds << "%#{search}%"
      end

      total_count = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.send(
          :sanitize_sql_array,
          [<<-SQL, *where_binds]
            SELECT COUNT(DISTINCT p.person_id)
            FROM person p
            LEFT JOIN person_name pn ON pn.person_id = p.person_id AND pn.voided = 0
            WHERE #{where_sql}
          SQL
        )
      ).to_i

      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.send(
          :sanitize_sql_array,
          [<<-SQL, *where_binds, per_page, (page - 1) * per_page]
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
            WHERE #{where_sql}
            GROUP BY p.person_id, p.birthdate, p.gender
            ORDER BY patient_name ASC
            LIMIT ? OFFSET ?
          SQL
        )
      )

      data = rows.map do |row|
        ActiveSupport::HashWithIndifferentAccess.new(
          patient_id: row['patient_id'],
          patient_name: row['patient_name'],
          patient_age: row['patient_age'],
          patient_gender: row['patient_gender']
        )
      end

      {
        data: data,
        pagination: {
          current_page: page,
          per_page: per_page,
          total_count: total_count,
          total_pages: (total_count.to_f / per_page).ceil
        }
      }
    end

    def self.empty_patient_page(page, per_page)
      {
        data: [],
        pagination: { current_page: page, per_page: per_page, total_count: 0, total_pages: 0 }
      }
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
