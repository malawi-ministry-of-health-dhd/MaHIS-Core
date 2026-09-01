# frozen_string_literal: true

require_relative '../incomplete_visits_evaluator'

module ArtService
  module Reports
    class VisitsReport
      include ModelUtils

      def initialize(name:, type:, start_date:, end_date:, **)
        @name = name
        @type = type
        @start_date = start_date.to_date
        @end_date = end_date.to_date
      end

      def build_report
        visits = (@start_date..@end_date).each_with_object({}) do |date, visits|
          visits[date] = calculate_daily_stats(date)
        end

        save_report visits
      end

      def calculate_daily_stats(date)
        stats = { incomplete: 0, complete: 0 }
        patients = find_visiting_patients(date)
        incomplete_patient_ids = incomplete_patient_ids(patients, date)

        patients.each do |patient|
          if incomplete_patient_ids.include?(patient.patient_id)
            stats[:incomplete] += 1
          else
            stats[:complete] += 1
          end
        end

        stats
      end

      def find_report
        (@start_date..@end_date).each_with_object({}) do |date, parsed_report|
          if date == Date.today
            parsed_report[date] = calculate_daily_stats(date)
            save_report({ date => parsed_report[date] })
            next
          end

          report = fetch_report date

          parsed_values = report.values.each_with_object({}) do |report_value, parsed_values|
            parsed_values[report_value.indicator_name] = report_value.contents.to_i
          end

          break nil if parsed_values.empty? # Force regeneration of report

          parsed_report[date] = parsed_values
        end
      end

      private

      def incomplete_patient_ids(patients, date)
        patient_visit_dates = patients.map { |patient| [patient.patient_id, date] }
        IncompleteVisitsEvaluator.new(program: hiv_program,
                                      patient_visit_dates:).call.keys
      end

      # Returns a list of patients who visited the ART clinic on given day.
      def find_visiting_patients(date)
        day_start, day_end = TimeUtils.day_bounds(date)
        query = <<~SQL
          SELECT patient.* FROM patient INNER JOIN encounter USING (patient_id)
           WHERE encounter.encounter_datetime BETWEEN ? AND ?
            AND encounter.encounter_type NOT IN (
              SELECT encounter_type_id FROM encounter_type WHERE name IN ('LAB', 'LAB ORDER', 'LAB ORDERS', 'LAB RESULTS')
            )
            AND encounter.program_id = #{hiv_program.program_id}
            AND encounter.voided = 0
            AND patient.voided = 0
           GROUP BY patient.patient_id
        SQL

        Patient.find_by_sql([query, day_start, day_end])
      end

      def hiv_program
        @hiv_program ||= program('HIV Program')
      end

      def save_report(visits)
        visits.each do |date, values|
          report = fetch_report date
          report.values.destroy_all

          values.each do |indicator, value|
            ReportValue.create name: "#{date} - #{indicator}",
                               indicator_name: indicator.to_s,
                               contents: value,
                               content_type: 'integer',
                               report:,
                               creator: User.first.user_id
          end
        end
      end

      def fetch_report(date)
        report = Report.find_by type: report_type('Visits'),
                                name: 'Daily visits',
                                start_date: date,
                                end_date: date
        report || create_report(date)
      end

      def create_report(date)
        Report.create type: fetch_report_type,
                      name: 'Daily visits',
                      start_date: date,
                      end_date: date,
                      renderer_type: 'Plain text',
                      creator: User.first.user_id
      end

      def fetch_report_type
        type = report_type('Visits')
        type || ReportType.create(name: 'Visits', creator: User.current.id)
      end
    end
  end
end
