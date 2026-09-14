# frozen_string_literal: true

# The IPD ward roster, resolved and paginated in SQL.
#
# The dashboard used to pull a ward's whole roster (`/stages?paginate=false`,
# plus every bed allocation) and do the merging, searching, counting and
# sorting in the browser. On a ward with a hundred patients that is a hundred
# serialized stages — each costing several un-preloaded queries — for a card
# that only ever shows a handful of rows.
#
# So the roster is built here instead: one derived table per bed-management
# mode, filtered and ordered in SQL, with LIMIT applied before any name lookup.
# The dashboard's counts and its two side panels come from #summary, which
# aggregates over the same roster rather than over a list the client holds.
#
# The roster definition mirrors ward_patients_service.ts exactly, because the
# "View all" list still builds it client-side:
#
#   required — active bed allocations ARE the roster.
#   disabled — the ward's ADMITTED_PATIENTS queue is the roster.
#   optional — the queue is the roster, decorated with any bed that was
#              recorded, and allocations with no queue row are appended.
class WardPatientsService
  ADMITTED_STAGE = 'ADMITTED_PATIENTS'
  PRE_ADMISSION_STAGE = 'PRE_ADMISSION'
  BED_MANAGEMENT_PROPERTY = 'ipd_bed_management_mode'
  DEFAULT_BED_MANAGEMENT_MODE = 'required'
  BED_MANAGEMENT_MODES = %w[required optional disabled].freeze

  # A patient is "new" for their first 24h in the ward and a long stay from day
  # seven, matching the status pills the dashboard renders.
  NEW_ADMISSION_DAYS = 1
  LONG_STAY_DAYS = 7

  PANEL_SIZE = 5

  # A bed is occupied when an active allocation holds it — beds carry no
  # occupancy column of their own. Covered by idx_bed_alloc_bed_status_released.
  OCCUPIED_BED = <<~SQL.squish
    EXISTS (
      SELECT 1 FROM bed_mgmt_bed_allocation ba
      WHERE ba.bed_id = b.bed_id
        AND ba.allocation_status = 'ACTIVE'
        AND ba.released_at IS NULL
        AND ba.voided = 0
    )
  SQL

  class << self
    # One page of the ward roster: { count:, page:, per_page:, results: [] }.
    def patients(filters = {})
      ward_id = filters[:ward_id].to_i
      return empty_page(filters) unless ward_id.positive?

      page = positive_integer(filters[:page], 1)
      per_page = positive_integer(filters[:per_page] || filters[:page_size], 8)
      offset = (page - 1) * per_page

      filters = filters.merge(mode: bed_management_mode)
      rows_sql = roster_rows_sql(ward_id, filters)

      rows = select_all(<<~SQL)
        #{rows_sql}
        ORDER BY admitted_at IS NULL, admitted_at DESC, row_key
        LIMIT #{per_page}
        OFFSET #{offset}
      SQL

      {
        count: total_for(rows_sql, rows, page, per_page),
        page:,
        per_page:,
        results: rows.map { |row| format_row(row) }
      }
    end

    # Everything the dashboard shows that is *about* the whole ward rather than
    # about the visible page: the KPI counts and the two bottom panels. Each
    # part is a bounded query, so the client never has to hold the roster to
    # work them out.
    def summary(filters = {})
      ward_id = filters[:ward_id].to_i
      return empty_summary unless ward_id.positive?

      filters = filters.merge(mode: bed_management_mode)
      counts = select_all(<<~SQL).first || {}
        SELECT
          COUNT(*) AS total,
          SUM(CASE WHEN days_in_ward < #{NEW_ADMISSION_DAYS} THEN 1 ELSE 0 END) AS admissions_today,
          SUM(CASE WHEN days_in_ward >= #{LONG_STAY_DAYS} THEN 1 ELSE 0 END) AS long_stay
        FROM (#{roster_rows_sql(ward_id, filters.except(:search, :status))}) roster
      SQL

      {
        counts: {
          total: counts['total'].to_i,
          admissions_today: counts['admissions_today'].to_i,
          long_stay: counts['long_stay'].to_i
        },
        awaiting_admission: awaiting_admission_count(ward_id, filters),
        bed_capacity: bed_capacity(ward_id, filters[:mode]),
        recent_admissions: panel_rows(ward_id, filters, status: 'new',
                                                        order: 'admitted_at IS NULL, admitted_at DESC, row_key'),
        long_stay_patients: panel_rows(ward_id, filters, status: nil,
                                                         order: 'days_in_ward DESC, admitted_at, row_key')
      }
    end

    def bed_management_mode
      mode = GlobalProperty.find_by(property: BED_MANAGEMENT_PROPERTY)&.property_value.to_s.strip.downcase
      BED_MANAGEMENT_MODES.include?(mode) ? mode : DEFAULT_BED_MANAGEMENT_MODE
    end

    private

    def panel_rows(ward_id, filters, status:, order:)
      sql = roster_rows_sql(ward_id, filters.except(:search).merge(status: status))

      select_all("#{sql} ORDER BY #{order} LIMIT #{PANEL_SIZE}").map { |row| format_row(row) }
    end

    # The full roster row: identity and bed columns from the mode's derived
    # table, names and demographics joined on, then the search and status
    # filters. Pagination happens outside this, so a page of eight resolves
    # eight patients' names however big the ward is.
    def roster_rows_sql(ward_id, filters)
      search_clause, search_binds = search_clause(filters[:search])
      status_clause = status_clause(filters[:status])

      sanitize_sql_array([
        <<~SQL,
          SELECT
            roster.*,
            pe.gender,
            pe.birthdate,
            pn.given_name,
            pn.family_name
          FROM (#{roster_sql(ward_id, filters)}) roster
          INNER JOIN person pe ON pe.person_id = roster.patient_id AND pe.voided = 0
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
          WHERE 1 = 1
            #{status_clause}
            #{search_clause}
        SQL
        *search_binds
      ])
    end

    def roster_sql(ward_id, filters)
      case filters[:mode] || bed_management_mode
      when 'required'
        allocation_roster_sql(ward_id, exclude_queued: false)
      when 'disabled'
        stage_roster_sql(ward_id, filters, with_beds: false)
      else
        <<~SQL
          #{stage_roster_sql(ward_id, filters, with_beds: true)}
          UNION ALL
          #{allocation_roster_sql(ward_id, exclude_queued: true, filters: filters)}
        SQL
      end
    end

    # The ward's ADMITTED_PATIENTS queue. `with_beds` decorates each row with the
    # patient's active allocation when the facility records beds sometimes —
    # the most recent one, so a patient carrying two never splits into two rows.
    def stage_roster_sql(ward_id, filters, with_beds:)
      program_clause, program_binds = program_clause(filters[:program_id], 's')

      bed_columns =
        if with_beds
          <<~SQL
            ba.bed_allocation_id,
            b.bed_number,
            sec.name AS section_name,
            sec.location_id AS section_location_id,
            w.name AS ward_name,
            w.location_id AS ward_location_id
          SQL
        else
          <<~SQL
            NULL AS bed_allocation_id,
            NULL AS bed_number,
            NULL AS section_name,
            NULL AS section_location_id,
            NULL AS ward_name,
            NULL AS ward_location_id
          SQL
        end

      bed_joins =
        if with_beds
          <<~SQL
            LEFT JOIN bed_mgmt_bed_allocation ba
              ON ba.bed_allocation_id = (
                SELECT ba2.bed_allocation_id
                FROM bed_mgmt_bed_allocation ba2
                WHERE ba2.patient_id = s.patient_id
                  AND ba2.allocation_status = '#{BedAllocation::ACTIVE_STATUS}'
                  AND ba2.released_at IS NULL
                  AND ba2.voided = 0
                ORDER BY ba2.allocated_at DESC, ba2.bed_allocation_id DESC
                LIMIT 1
              )
            LEFT JOIN bed_mgmt_bed b ON b.bed_id = ba.bed_id
            LEFT JOIN location sec ON sec.location_id = b.section_id
            LEFT JOIN location w ON w.location_id = sec.parent_location
          SQL
        else
          ''
        end

      sanitize_sql_array([
        <<~SQL,
          SELECT
            CONCAT('patient-', s.patient_id) AS row_key,
            s.patient_id,
            s.visit_id,
            #{bed_columns},
            COALESCE(s.arrival_time, s.created_at) AS admitted_at,
            v.date_started AS visit_date_started,
            TIMESTAMPDIFF(DAY, COALESCE(s.arrival_time, s.created_at), NOW()) AS days_in_ward
          FROM stages s
          INNER JOIN visit v ON v.visit_id = s.visit_id AND v.date_stopped IS NULL
          #{bed_joins}
          WHERE s.status = 1
            AND s.stage = ?
            AND s.location_id = ?
            #{program_clause}
        SQL
        ADMITTED_STAGE,
        ward_id,
        *program_binds
      ])
    end

    # Active allocations on beds in the ward's sections. `exclude_queued` drops
    # the patients the queue already contributed, so the optional-mode union
    # appends bed holders rather than duplicating them.
    def allocation_roster_sql(ward_id, exclude_queued:, filters: {})
      binds = [ward_id, ward_id]
      queued_clause = ''

      if exclude_queued
        program_clause, program_binds = program_clause(filters[:program_id], 's2')
        queued_clause = <<~SQL
          AND NOT EXISTS (
            SELECT 1
            FROM stages s2
            INNER JOIN visit v2 ON v2.visit_id = s2.visit_id AND v2.date_stopped IS NULL
            WHERE s2.patient_id = ba.patient_id
              AND s2.status = 1
              AND s2.stage = ?
              AND s2.location_id = ?
              #{program_clause}
          )
        SQL
        binds += [ADMITTED_STAGE, ward_id, *program_binds]
      end

      sanitize_sql_array([
        <<~SQL,
          SELECT
            CONCAT('allocation-', ba.bed_allocation_id) AS row_key,
            ba.patient_id,
            ba.visit_id,
            ba.bed_allocation_id,
            b.bed_number,
            sec.name AS section_name,
            sec.location_id AS section_location_id,
            w.name AS ward_name,
            w.location_id AS ward_location_id,
            ba.allocated_at AS admitted_at,
            v.date_started AS visit_date_started,
            TIMESTAMPDIFF(DAY, ba.allocated_at, NOW()) AS days_in_ward
          FROM bed_mgmt_bed_allocation ba
          INNER JOIN bed_mgmt_bed b ON b.bed_id = ba.bed_id
          INNER JOIN location sec ON sec.location_id = b.section_id
          LEFT JOIN location w ON w.location_id = sec.parent_location
          LEFT JOIN visit v ON v.visit_id = ba.visit_id
          WHERE ba.allocation_status = '#{BedAllocation::ACTIVE_STATUS}'
            AND ba.released_at IS NULL
            AND ba.voided = 0
            AND (sec.location_id = ? OR sec.parent_location = ?)
            #{queued_clause}
        SQL
        *binds
      ])
    end

    # The ward's pre-admission queue, counted rather than listed: the KPI shows
    # a number, and the queue itself lives on its own screen.
    def awaiting_admission_count(ward_id, filters)
      program_clause, program_binds = program_clause(filters[:program_id], 's')

      select_value(sanitize_sql_array([
        <<~SQL,
          SELECT COUNT(*)
          FROM stages s
          INNER JOIN visit v ON v.visit_id = s.visit_id AND v.date_stopped IS NULL
          WHERE s.status = 1
            AND s.stage = ?
            AND s.location_id = ?
            #{program_clause}
        SQL
        PRE_ADMISSION_STAGE,
        ward_id,
        *program_binds
      ])).to_i
    end

    # The ward's bed inventory as four numbers.
    #
    # The dashboard used to work these out by listing the ward's sections and
    # then fetching every bed in each one — a request per section, and a query
    # per bed on the server to resolve its occupancy. It only ever renders the
    # totals, so count them here instead. A facility with beds turned off has no
    # inventory to report.
    def bed_capacity(ward_id, mode)
      return empty_bed_capacity if (mode || bed_management_mode) == 'disabled'

      row = select_all(sanitize_sql_array([
        <<~SQL,
          SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN #{OCCUPIED_BED} THEN 1 ELSE 0 END) AS occupied,
            SUM(CASE WHEN b.bed_status = 'ACTIVE' AND NOT #{OCCUPIED_BED} THEN 1 ELSE 0 END) AS available,
            SUM(CASE WHEN b.bed_status IN ('MAINTENANCE', 'BLOCKED', 'INACTIVE') THEN 1 ELSE 0 END) AS maintenance
          FROM bed_mgmt_bed b
          INNER JOIN location sec ON sec.location_id = b.section_id
          WHERE b.retired = 0
            AND (sec.location_id = ? OR sec.parent_location = ?)
        SQL
        ward_id,
        ward_id
      ])).first || {}

      {
        total: row['total'].to_i,
        occupied: row['occupied'].to_i,
        available: row['available'].to_i,
        maintenance: row['maintenance'].to_i,
        has_bed_data: row['total'].to_i.positive?
      }
    end

    def empty_bed_capacity
      { total: 0, occupied: 0, available: 0, maintenance: 0, has_bed_data: false }
    end

    def program_clause(program_id, table_alias)
      return ['', []] if program_id.blank?

      ["AND #{table_alias}.program_id = ?", [program_id.to_i]]
    end

    # Matches the dashboard's own search box: bed, name or patient id.
    def search_clause(search)
      term = search.to_s.strip
      term = '' if term.match?(/\A(undefined|null)\z/i)
      return ['', []] if term.blank?

      like = "%#{ActiveRecord::Base.sanitize_sql_like(term.downcase)}%"

      [
        <<~SQL.squish,
          AND (
            LOWER(CONCAT(COALESCE(pn.given_name, ''), ' ', COALESCE(pn.family_name, ''))) LIKE ?
            OR LOWER(COALESCE(roster.bed_number, '')) LIKE ?
            OR CAST(roster.patient_id AS CHAR) LIKE ?
          )
        SQL
        [like, like, like]
      ]
    end

    def status_clause(status)
      case status.to_s.strip.downcase
      when 'new' then "AND roster.days_in_ward < #{NEW_ADMISSION_DAYS}"
      when 'longstay' then "AND roster.days_in_ward >= #{LONG_STAY_DAYS}"
      when 'admitted'
        "AND roster.days_in_ward >= #{NEW_ADMISSION_DAYS} AND roster.days_in_ward < #{LONG_STAY_DAYS}"
      else ''
      end
    end

    # A ward that fits on one page needs no COUNT: the page is the roster.
    def total_for(rows_sql, rows, page, per_page)
      return rows.length if page == 1 && rows.length < per_page

      select_value("SELECT COUNT(*) FROM (#{rows_sql}) ward_roster").to_i
    end

    # The shape ward_patients_service.ts already maps, so the dashboard rows are
    # built from the same fields whether they came from here or from the client.
    def format_row(row)
      {
        row_key: row['row_key'],
        patient_id: row['patient_id'],
        visit_id: row['visit_id'],
        bed_allocation_id: row['bed_allocation_id'],
        given_name: row['given_name'],
        family_name: row['family_name'],
        gender: row['gender'],
        birthdate: row['birthdate'],
        bed_number: row['bed_number'],
        section_name: row['section_name'],
        section_location_id: row['section_location_id'],
        ward_name: row['ward_name'],
        ward_location_id: row['ward_location_id'],
        admitted_at: row['admitted_at'],
        visit_date_started: row['visit_date_started'],
        days_in_ward: row['days_in_ward'].to_i
      }
    end

    def empty_page(filters)
      {
        count: 0,
        page: positive_integer(filters[:page], 1),
        per_page: positive_integer(filters[:per_page] || filters[:page_size], 8),
        results: []
      }
    end

    def empty_summary
      {
        counts: { total: 0, admissions_today: 0, long_stay: 0 },
        awaiting_admission: 0,
        bed_capacity: empty_bed_capacity,
        recent_admissions: [],
        long_stay_patients: []
      }
    end

    def select_all(sql)
      ActiveRecord::Base.connection.select_all(sql)
    end

    def select_value(sql)
      ActiveRecord::Base.connection.select_value(sql)
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
