# frozen_string_literal: true

module ArtService
  module Reports
    # Cohort report builder class.
    #
    # This class only provides one public method (start_build_report) besides
    # the constructor. This method must be called to build report and save
    # it to database.
    class ArtCohort
      include ConcurrencyUtils
      include ModelUtils
      include ArtTempTablesNaming

      def lock_file
        "art_service/reports/cohort_#{Location.current.location_id}.lock"
      end

      def initialize(name:, type:, start_date:, end_date:, **kwargs)
        @name = name
        @start_date = start_date
        @end_date = end_date
        @type = type
        @rebuild = kwargs[:rebuild].to_s.casecmp?('true') || kwargs[:rebuild] == true
        @cohort_builder = CohortBuilder.new
        @cohort_struct = CohortStruct.new
        @occupation = kwargs[:occupation]
        @cohort_builder.ws_name = name
        @cohort_builder.ws_location_id = Location.current&.location_id
      end

      def build_report
        with_lock(lock_file, blocking: false) do
          @cohort_builder.build(@cohort_struct, @start_date, @end_date, @occupation, force_rebuild: @rebuild)
          clear_drill_down
          save_report
          # Broadcast completion AFTER the report is persisted so the frontend's
          # follow-up requestCohort call finds the saved data immediately.
          @cohort_builder.broadcast_completion
        end
      rescue FailedToAcquireLock => e
        Rails.logger.warn("ART#Cohort report is locked by another process: #{e}")
      end

      def find_report
        # Find or create ReportType if @type is an OpenStruct
        report_type = if @type.is_a?(OpenStruct)
                        ReportType.find_or_create_by(name: @type.name) do |rt|
                          rt.creator = User.current.id
                        end
                      else
                        @type
                      end

        Report.where(type: report_type, name: "#{@name} #{@occupation}",
                     start_date: @start_date, end_date: @end_date)\
              .order(date_created: :desc)\
              .first
      end

      def defaulter_list(pepfar)
        report_type = (pepfar ? 'pepfar' : 'moh')
        ArtService::Reports::CohortBuilder.new(outcomes_definition: report_type)
                                          .init_temporary_tables(@start_date, @end_date, @occupation)

        ActiveRecord::Base.connection.select_all <<~SQL
          SELECT
            e.patient_id person_id, i.identifier arv_number, e.birthdate,
            e.gender, n.given_name, n.family_name,
            art_reason.name art_reason, a.value cell_number, landmark.value landmark,
            s.state_province district, s.county_district ta,
            s.city_village village, TIMESTAMPDIFF(year, DATE(e.birthdate), DATE('#{@end_date}')) age,
            o.#{report_type&.downcase == 'pepfar' ? 'pepfar_' : 'moh_'}outcome_date AS defaulter_date,
            DATE(appointment.appointment_date) AS appointment_date
          FROM #{temp_earliest_start_date} e
          INNER JOIN #{temp_patient_outcomes} o ON e.patient_id = o.patient_id
          INNER JOIN patient_program pp ON pp.patient_id = e.patient_id
            AND pp.program_id = 1
            AND pp.voided = 0
            AND pp.location_id = #{User.current.location_id}
          INNER JOIN (
            SELECT e.patient_id, MAX(o.value_datetime) appointment_date
            FROM encounter e
            INNER JOIN obs o ON o.encounter_id = e.encounter_id AND o.voided = 0 AND o.concept_id = 5096 -- appointment date
            WHERE e.encounter_type = 7 -- appointment encounter type
            AND e.program_id = (SELECT program_id FROM program WHERE name = 'HIV PROGRAM' LIMIT 1)
            AND e.patient_id IN (SELECT patient_id FROM #{temp_patient_outcomes} WHERE #{report_type&.downcase == 'pepfar' ? 'pepfar_' : 'moh_'}cum_outcome = 'Defaulted')
            AND e.encounter_datetime < DATE('#{@end_date}') + INTERVAL 1 DAY
            GROUP BY e.patient_id
          ) appointment ON appointment.patient_id = e.patient_id
          LEFT JOIN patient_identifier i ON i.patient_id = e.patient_id#{' '}
            AND i.voided = 0#{' '}
            AND i.identifier_type = (
              SELECT patient_identifier_type_id#{' '}
              FROM patient_identifier_type#{' '}
              WHERE name = 'ARV Number'#{' '}
              LIMIT 1
            )
          INNER JOIN person_name n ON n.person_id = e.patient_id AND n.voided = 0
          LEFT JOIN person_attribute a ON a.person_id = e.patient_id AND a.voided = 0 AND a.person_attribute_type_id = 12
          LEFT JOIN person_attribute landmark ON landmark.person_id = e.patient_id AND landmark.voided = 0 AND landmark.person_attribute_type_id = 19
          LEFT JOIN person_address s ON s.person_id = e.patient_id AND s.voided = 0
          LEFT JOIN concept_name art_reason ON art_reason.concept_id = e.reason_for_starting_art AND art_reason.voided = 0
          WHERE o.#{report_type&.downcase == 'pepfar' ? 'pepfar_' : 'moh_'}cum_outcome = 'Defaulted'
          GROUP BY e.patient_id
          HAVING (defaulter_date >= DATE('#{@start_date}') AND defaulter_date <= DATE('#{@end_date}')) OR (defaulter_date IS NULL)
          ORDER BY e.patient_id, n.date_created DESC;
        SQL
      end

      private

      def cleanup_tables
        Rails.logger.info("Cleaning up temporary tables for location #{Location.current&.location_id}")
        @cohort_builder.cleanup_temporary_tables
      rescue StandardError => e
        Rails.logger.error("Failed to cleanup temporary tables: #{e.message}")
      end

      public

      def cohort_report_drill_down(id)
        id = ActiveRecord::Base.connection.quote(id)

        # Query permanent tables directly since temp tables are cleaned up after report generation
        # The cohort_drill_down table already has the correct patient IDs from report generation
        ActiveRecord::Base.connection.select_all <<~SQL
          WITH
            cohort_patients AS (
              SELECT DISTINCT patient_id
              FROM cohort_drill_down
              WHERE reporting_report_design_resource_id = #{id}
            ),
            arv_type_id AS (
              SELECT patient_identifier_type_id
              FROM patient_identifier_type
              WHERE name = 'ARV Number'
              LIMIT 1
            ),
            hiv_program_id AS (
              SELECT program_id
              FROM program
              WHERE name = 'HIV PROGRAM'
              LIMIT 1
            ),
            art_start_concept AS (
              SELECT concept_id
              FROM concept_name
              WHERE name = 'ART start date' AND voided = 0
              LIMIT 1
            ),
            arv_drugs_set AS (
              SELECT cs.concept_id
              FROM concept_set cs
              INNER JOIN concept_name cn
                ON cn.concept_id = cs.concept_set
                AND cn.name = 'Antiretroviral drugs'
                AND cn.voided = 0
            ),
            tb_status_concept AS (
              SELECT concept_id
              FROM concept_name
              WHERE name = 'TB status' AND voided = 0
              LIMIT 1
            ),
            latest_state AS (
              SELECT pst.patient_program_id, MAX(pst.start_date) AS max_start_date
              FROM patient_state pst
              INNER JOIN patient_program pp ON pp.patient_program_id = pst.patient_program_id
              INNER JOIN cohort_patients cp ON cp.patient_id = pp.patient_id
              WHERE pst.voided = 0
              GROUP BY pst.patient_program_id
            ),
            patient_art_start AS (
              SELECT o.person_id, MIN(o.value_datetime) AS art_start_date
              FROM obs o
              INNER JOIN cohort_patients cp ON cp.patient_id = o.person_id
              WHERE o.concept_id = (SELECT concept_id FROM art_start_concept)
                AND o.voided = 0
              GROUP BY o.person_id
            ),
            patient_arv_orders AS (
              SELECT o.patient_id, MIN(o.start_date) AS first_order_date
              FROM orders o
              INNER JOIN cohort_patients cp ON cp.patient_id = o.patient_id
              WHERE o.concept_id IN (SELECT concept_id FROM arv_drugs_set)
                AND o.voided = 0
              GROUP BY o.patient_id
            ),
            patient_tb_obs AS (
              SELECT o.person_id, MAX(o.obs_datetime) AS tb_obs_date
              FROM obs o
              INNER JOIN cohort_patients cp ON cp.patient_id = o.person_id
              WHERE o.concept_id = (SELECT concept_id FROM tb_status_concept)
                AND o.voided = 0
              GROUP BY o.person_id
            )
          SELECT i.identifier arv_number, p.birthdate,
                 p.gender, n.given_name, n.family_name, p.person_id person_id,
                 ps.name AS outcome,
                 DATE(COALESCE(pas.art_start_date, pao.first_order_date)) AS art_start_date,
                 DATE(ptb.tb_obs_date) tb_observation_date
          FROM cohort_patients cp
          INNER JOIN person p ON p.person_id = cp.patient_id AND p.voided = 0
          LEFT JOIN patient_identifier i ON i.patient_id = p.person_id
            AND i.voided = 0
            AND i.identifier_type = (SELECT patient_identifier_type_id FROM arv_type_id)
          LEFT JOIN person_name n ON n.person_id = p.person_id AND n.voided = 0
          LEFT JOIN patient_program pp ON pp.patient_id = p.person_id
            AND pp.program_id = (SELECT program_id FROM hiv_program_id)
            AND pp.voided = 0
          LEFT JOIN latest_state ls ON ls.patient_program_id = pp.patient_program_id
          LEFT JOIN patient_state pst ON pst.patient_program_id = pp.patient_program_id
            AND pst.voided = 0
            AND pst.start_date = ls.max_start_date
          LEFT JOIN program_workflow_state pws ON pws.program_workflow_state_id = pst.state
          LEFT JOIN concept_name ps ON ps.concept_id = pws.concept_id AND ps.voided = 0
          LEFT JOIN patient_art_start pas ON pas.person_id = p.person_id
          LEFT JOIN patient_arv_orders pao ON pao.patient_id = p.person_id
          LEFT JOIN patient_tb_obs ptb ON ptb.person_id = p.person_id
          GROUP BY p.person_id ORDER BY p.person_id, p.date_created;
        SQL
      end

      LOGGER = Rails.logger

      def find_saved_report
        # Find or create ReportType if @type is an OpenStruct
        report_type = if @type.is_a?(OpenStruct)
                        ReportType.find_or_create_by(name: @type.name) do |rt|
                          rt.creator = User.current.id
                        end
                      else
                        @type
                      end

        @report = Report.where(type: report_type, name: "#{@name} #{@occupation}",
                               start_date: @start_date, end_date: @end_date)
        @report&.map { |r| r['id'] } || []
      end

      # Writes the report to database
      def save_report
        Report.transaction do
          # Find or create ReportType if @type is an OpenStruct
          report_type = if @type.is_a?(OpenStruct)
                          ReportType.find_or_create_by(name: @type.name) do |rt|
                            rt.creator = User.current.id
                          end
                        else
                          @type
                        end

          report = Report.create(name: "#{@name} #{@occupation}",
                                 start_date: @start_date,
                                 end_date: @end_date,
                                 type: report_type,
                                 creator: User.current.id,
                                 renderer_type: 'PDF')

          values = save_report_values(report)

          { report:, values: }
        end
      end

      # Writes the report values to database using bulk inserts to avoid N+1 queries.
      # Instead of 3 queries per indicator (INSERT + audit INSERT + User Load),
      # this performs: 1 bulk INSERT + 1 SELECT (by UUID) + 1 bulk audit INSERT.
      def save_report_values(report)
        return [] if @cohort_struct.values.blank?

        now = Time.current
        user_id = User.current.user_id
        request_uuid = SecureRandom.uuid

        # Pair each cohort value with a pre-generated UUID for later correlation
        values_with_uuids = @cohort_struct.values.map { |v| [v, SecureRandom.uuid] }

        # 1. Bulk INSERT all report value rows — bypasses per-row callbacks and auditing
        ReportValue.insert_all!(values_with_uuids.map { |value, uuid|
          {
            uuid:,
            name: value.name,
            indicator_name: value.indicator_name,
            indicator_short_name: value.indicator_short_name,
            description: value.description,
            contents: value_contents_to_json(value.contents).to_s,
            report_design_id: report.id,
            creator: user_id,
            changed_by: user_id,
            date_created: now,
            date_changed: now,
            retired: false
          }
        })

        # 2. Fetch back inserted rows to get DB-assigned IDs; unscoped avoids retired=0 default scope
        uuids = values_with_uuids.map(&:last)
        saved_by_uuid = ReportValue.unscoped.where(uuid: uuids).index_by(&:uuid)

        # 3. Bulk INSERT one audit record per report value (one shared request_uuid per job run)
        Audited::Audit.insert_all!(values_with_uuids.map { |_value, uuid|
          rv = saved_by_uuid[uuid]
          {
            auditable_id: rv.id,
            auditable_type: 'ReportValue',
            action: 'create',
            audited_changes: rv.audited_attributes.to_yaml,
            version: 1,
            user_id:,
            user_type: 'User',
            request_uuid:,
            created_at: now
          }
        })

        # 4. Collect all (resource_id, patient_id) pairs across every indicator, then
        #    bulk INSERT in one pass (batched at 1_000 rows to stay within max_allowed_packet)
        report_values = values_with_uuids.map { |_value, uuid| saved_by_uuid[uuid] }

        all_pairs = values_with_uuids.flat_map { |value, uuid|
          rv = saved_by_uuid[uuid]
          extract_patient_ids(value.contents).map { |pid| "(#{rv.id}, #{pid})" }
        }

        all_pairs.each_slice(50_000) do |batch|
          ActiveRecord::Base.connection.execute <<~SQL
            INSERT INTO cohort_drill_down (reporting_report_design_resource_id, patient_id)
            VALUES #{batch.join(',')};
          SQL
        end

        report_values
      end

      def clear_drill_down
        # Find existing reporting_report_design records for this cohort/date range
        # Match on start_date and end_date (name is unreliable as it gets stored inconsistently)
        existing_designs = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT id FROM reporting_report_design
          WHERE start_date = '#{@start_date}'
            AND end_date = '#{@end_date}'
        SQL

        design_ids = existing_designs.map { |d| d['id'] }
        return if design_ids.blank?

        LOGGER.info("Clear drill-down: Found #{design_ids.count} existing designs with date range #{@start_date} to #{@end_date}")

        # Find all resource IDs for these designs
        resource_ids = ActiveRecord::Base.connection.select_all <<~SQL
          SELECT id FROM reporting_report_design_resource
          WHERE report_design_id IN (#{design_ids.join(',')})
        SQL

        resource_id_list = resource_ids.map { |r| r['id'] }

        # Delete in proper order: child records first
        unless resource_id_list.blank?
          ActiveRecord::Base.connection.execute <<~SQL
            DELETE FROM cohort_drill_down WHERE reporting_report_design_resource_id IN (#{resource_id_list.join(',')})
          SQL
          LOGGER.info("Clear drill-down: Deleted drill-down records for #{resource_id_list.count} resources")
        end

        ActiveRecord::Base.connection.execute <<~SQL
          DELETE FROM reporting_report_design_resource WHERE report_design_id IN (#{design_ids.join(',')})
        SQL

        ActiveRecord::Base.connection.execute <<~SQL
          DELETE FROM reporting_report_design WHERE id IN (#{design_ids.join(',')})
        SQL

        LOGGER.info("Clear drill-down: Deleted #{design_ids.count} report designs and their resources")
      end

      def value_contents_to_json(value_contents)
        if value_contents.respond_to?(:each) && !value_contents.is_a?(String)
          if value_contents.respond_to?(:length)
            value_contents.length
          elsif value_contents.respond_to?(:size)
            value_contents.size
          else
            value_contents
          end
        else
          value_contents
        end
      end

      PATIENT_ID_KEYS = ['patient_id', :patient_id, 'person_id', :person_id].freeze

      # Resolves a collection of patient/person entries to an array of integer IDs,
      # filtering out blanks and zeros.
      def extract_patient_ids(values)
        return [] if values.blank? || !values.respond_to?(:each)

        get_patient_id = lambda do |patient, keys = PATIENT_ID_KEYS|
          break nil if keys.empty?

          patient[keys.first] || get_patient_id[patient, keys[1..keys.size]]
        end

        values.filter_map do |patient|
          pid = if patient.respond_to?(:key?) && PATIENT_ID_KEYS.any? { |key| patient.key?(key) }
                  get_patient_id[patient]
                elsif patient.respond_to?(:each) && patient.respond_to?(:first)
                  patient.first
                else
                  patient
                end
          pid unless pid.blank? || pid.to_i.zero?
        end
      end

      def save_patients(r, values)
        patient_ids = extract_patient_ids(values)
        return if patient_ids.empty?

        patient_ids.each_slice(50_000) do |batch|
          rows = batch.map { |pid| "(#{r.id}, #{pid})" }.join(',')
          ActiveRecord::Base.connection.execute <<~SQL
            INSERT INTO cohort_drill_down (reporting_report_design_resource_id, patient_id)
            VALUES #{rows};
          SQL
        end
      end

      def calculate_age(birthdate)
        birthdate = begin
          birthdate.to_date
        rescue StandardError
          nil
        end
        return 'N/A' if birthdate.blank?

        birthdate = ActiveRecord::Base.connection.select_one <<~SQL
          SELECT TIMESTAMPDIFF(year, DATE('#{birthdate}'), DATE('#{@end_date}')) age;
        SQL

        birthdate['age']
      end
    end
  end
end
