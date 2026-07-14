# frozen_string_literal: true

# Facility-wide queue of patients who have lab orders with no results entered
# yet. This is the lab-side analogue of
# DrugOrderService.patients_awaiting_dispensation.
#
# "Order without results" is defined exactly as the lab gem defines it
# (Lab::OrdersSearchService.find_orders_without_results): a lab order whose
# order_id has no non-voided "Lab test result" observation. We scope to the same
# order types the gem recognises (Lab::Metadata::ORDER_TYPE_NAME and
# HTS_ORDER_TYPE_NAME) so this queue matches what the per-patient lab UI shows.
class LabResultsQueueService
  LAB_ORDER_TYPE_NAMES = [
    Lab::Metadata::ORDER_TYPE_NAME,
    Lab::Metadata::HTS_ORDER_TYPE_NAME
  ].freeze
  LAB_RESULT_CONCEPT_NAME = Lab::Metadata::TEST_RESULT_CONCEPT_NAME

  class << self
    def patients_awaiting_results(filters = {})
      page = positive_integer(filters[:page], 1)
      per_page = positive_integer(filters[:per_page] || filters[:page_size], 1000)
      offset = (page - 1) * per_page
      location_id = filters[:location_id].presence || User.current&.location_id

      pending_sql = pending_lab_results_patients_sql(location_id)

      rows = ActiveRecord::Base.connection.select_all(
        sanitize_sql_array([
          <<~SQL
            SELECT
              pending.patient_id,
              pending.encounter_datetime,
              pending.location_id,
              pending.program_ids,
              pending.program_names,
              pe.gender,
              pn.given_name,
              pn.family_name
            FROM (#{pending_sql}) pending
            INNER JOIN patient p ON p.patient_id = pending.patient_id
            INNER JOIN person pe ON pe.person_id = p.patient_id AND pe.voided = 0
            LEFT JOIN person_name pn
              ON pn.person_id = pe.person_id
             AND pn.voided = 0
             AND pn.person_name_id = (
               SELECT pn2.person_name_id
               FROM person_name pn2
               WHERE pn2.person_id = pe.person_id
                 AND pn2.voided = 0
               ORDER BY pn2.date_created DESC, pn2.person_name_id DESC
               LIMIT 1
             )
            ORDER BY pending.encounter_datetime DESC
            LIMIT #{per_page}
            OFFSET #{offset}
          SQL
        ])
      )

      # The awaiting-results queue is small, so it almost always fits on a single
      # page. In that case derive the total from the page we already have and skip
      # the COUNT query, which would otherwise re-run the full (costly) pending
      # aggregation a second time.
      count =
        if page == 1 && rows.length < per_page
          rows.length
        else
          ActiveRecord::Base.connection.select_value(
            "SELECT COUNT(*) FROM (#{pending_sql}) pending_lab_patients"
          ).to_i
        end

      {
        count:,
        page:,
        per_page:,
        results: rows.map { |row| format_row(row) }
      }
    end

    private

    def pending_lab_results_patients_sql(location_id)
      # Resolve the lab order-type and result-concept id(s) once so the main scan
      # can filter orders directly by order_type_id (indexed) and the per-order
      # existence check is a direct, indexed obs lookup — instead of joining to
      # order_type and concept_name for every candidate order.
      order_type_ids = lab_order_type_ids
      result_concept_ids = lab_result_concept_ids

      # No configured lab order types means nothing can be a lab order.
      return 'SELECT NULL AS patient_id WHERE 1 = 0' if order_type_ids.empty?

      where_clauses = [
        'lo.voided = 0',
        'e.voided = 0',
        'lo.order_type_id IN (?)'
      ]
      binds = [order_type_ids]

      # A lab order has results once it has a non-voided "Lab test result" obs.
      # When the concept is missing nothing counts as resulted, matching the
      # previous join's behaviour.
      if result_concept_ids.any?
        where_clauses << <<~SQL.squish
          NOT EXISTS (
            SELECT 1
            FROM obs result_obs
            WHERE result_obs.order_id = lo.order_id
              AND result_obs.voided = 0
              AND result_obs.concept_id IN (?)
          )
        SQL
        binds << result_concept_ids
      end

      if location_id.present?
        where_clauses << 'e.location_id = ?'
        binds << location_id
      end

      sanitize_sql_array([
        <<~SQL,
          SELECT
            lo.patient_id,
            MAX(e.encounter_datetime) AS encounter_datetime,
            MAX(e.location_id) AS location_id,
            GROUP_CONCAT(DISTINCT e.program_id ORDER BY e.program_id SEPARATOR ',') AS program_ids,
            GROUP_CONCAT(DISTINCT prg.name ORDER BY prg.name SEPARATOR ', ') AS program_names
          FROM orders lo
          INNER JOIN encounter e ON e.encounter_id = lo.encounter_id
          LEFT JOIN program prg ON prg.program_id = e.program_id
          WHERE #{where_clauses.join(' AND ')}
          GROUP BY lo.patient_id
        SQL
        *binds
      ])
    end

    def lab_order_type_ids
      OrderType.where(name: LAB_ORDER_TYPE_NAMES).distinct.pluck(:order_type_id)
    end

    def lab_result_concept_ids
      ConceptName.where(voided: 0, name: LAB_RESULT_CONCEPT_NAME).distinct.pluck(:concept_id)
    end

    def format_row(row)
      program_names = row['program_names'].to_s.split(', ').reject(&:blank?)

      {
        patient_id: row['patient_id'].to_s,
        given_name: row['given_name'],
        family_name: row['family_name'],
        full_name: [row['given_name'], row['family_name']].compact.join(' ').strip,
        gender: row['gender'],
        encounter_datetime: row['encounter_datetime'],
        location_id: row['location_id']&.to_s,
        program_ids: row['program_ids'].to_s.split(',').reject(&:blank?).map(&:to_i),
        program_names:,
        source_label: program_names.presence&.join(', ') || 'Lab orders'
      }
    end

    def positive_integer(value, fallback)
      integer = value.to_i
      integer.positive? ? integer : fallback
    end

    def sanitize_sql_array(values)
      ActiveRecord::Base.send(:sanitize_sql_array, values)
    end
  end
end
