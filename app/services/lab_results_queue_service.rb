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
      count = ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM (#{pending_sql}) pending_lab_patients"
      ).to_i

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

      {
        count:,
        page:,
        per_page:,
        results: rows.map { |row| format_row(row) }
      }
    end

    private

    def pending_lab_results_patients_sql(location_id)
      where_clauses = [
        'lo.voided = 0',
        'e.voided = 0',
        'ot.name IN (?)',
        <<~SQL.squish
          NOT EXISTS (
            SELECT 1
            FROM obs result_obs
            INNER JOIN concept_name cn
              ON cn.concept_id = result_obs.concept_id
             AND cn.voided = 0
            WHERE result_obs.order_id = lo.order_id
              AND result_obs.voided = 0
              AND cn.name = ?
          )
        SQL
      ]
      binds = [LAB_ORDER_TYPE_NAMES, LAB_RESULT_CONCEPT_NAME]

      if location_id.present?
        where_clauses << 'e.location_id = ?'
        binds << location_id
      end

      sanitize_sql_array([
        <<~SQL,
          SELECT
            lo.patient_id,
            MAX(lo.start_date) AS encounter_datetime,
            MAX(e.location_id) AS location_id,
            GROUP_CONCAT(DISTINCT e.program_id ORDER BY e.program_id SEPARATOR ',') AS program_ids,
            GROUP_CONCAT(DISTINCT prg.name ORDER BY prg.name SEPARATOR ', ') AS program_names
          FROM orders lo
          INNER JOIN order_type ot ON ot.order_type_id = lo.order_type_id
          INNER JOIN encounter e ON e.encounter_id = lo.encounter_id
          LEFT JOIN program prg ON prg.program_id = e.program_id
          WHERE #{where_clauses.join(' AND ')}
          GROUP BY lo.patient_id
        SQL
        *binds
      ])
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
