# frozen_string_literal: true

require 'rails_helper'

describe Report do
  describe 'cascade delete for drill-down records' do
    let(:report_type) { ReportType.create!(name: 'Test Report', creator: 1) }
    let(:start_date) { Date.parse('2026-01-01') }
    let(:end_date) { Date.parse('2026-03-31') }

    before(:each) do
      # User should already exist from db:seed, so just ensure it's set
      User.current ||= User.find_by(user_id: 1) || User.first

      # Clean up existing data
      CohortDrillDown.delete_all
      ReportValue.delete_all
      Report.delete_all
    end

    it 'deletes associated drill-down records when report is destroyed' do
      # Create a report with values and drill-down records
      report = Report.create!(
        name: 'Cohort',
        type: report_type,
        start_date: start_date,
        end_date: end_date,
        renderer_type: 'org.openmrs.module.reporting.report.renderer.CohortDetailReportRenderer',
        creator: 1,
        uuid: SecureRandom.uuid
      )

      # Create report values
      value1 = ReportValue.create!(
        report: report,
        name: 'total_registered',
        indicator_name: 'Total Registered',
        indicator_short_name: 'TR',
        contents: '10',
        creator: 1,
        uuid: SecureRandom.uuid
      )

      value2 = ReportValue.create!(
        report: report,
        name: 'no_tb',
        indicator_name: 'No TB',
        indicator_short_name: 'NTB',
        contents: '5',
        creator: 1,
        uuid: SecureRandom.uuid
      )

      # Create drill-down records for each value
      3.times do |i|
        CohortDrillDown.create!(
          reporting_report_design_resource_id: value1.id,
          patient_id: 100 + i
        )
      end

      2.times do |i|
        CohortDrillDown.create!(
          reporting_report_design_resource_id: value2.id,
          patient_id: 200 + i
        )
      end

      # Verify initial state
      expect(Report.count).to eq(1)
      expect(ReportValue.count).to eq(2)
      expect(CohortDrillDown.count).to eq(5)

      # Store IDs for verification
      report_id = report.id
      value1_id = value1.id
      value2_id = value2.id

      # Destroy the report (simulating regeneration)
      report.destroy

      # Verify everything is cleaned up
      expect(Report.where(id: report_id).count).to eq(0)
      expect(ReportValue.where(id: [value1_id, value2_id]).count).to eq(0)
      expect(CohortDrillDown.count).to eq(0)

      # Verify no orphaned drill-down records exist
      orphaned_count = ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT COUNT(*)
        FROM cohort_drill_down c
        LEFT JOIN reporting_report_design_resource r#{' '}
          ON c.reporting_report_design_resource_id = r.id
        WHERE r.id IS NULL
      SQL

      expect(orphaned_count).to eq(0),
                                "Expected 0 orphaned drill-down records, found #{orphaned_count}"
    end

    it 'prevents orphan accumulation after multiple regenerations' do
      3.times do |iteration|
        # Create report
        report = Report.create!(
          name: 'Cohort',
          type: report_type,
          start_date: start_date,
          end_date: end_date,
          renderer_type: 'org.openmrs.module.reporting.report.renderer.CohortDetailReportRenderer',
          creator: 1,
          uuid: SecureRandom.uuid
        )

        # Create values with drill-down
        value = ReportValue.create!(
          report: report,
          name: 'test_metric',
          indicator_name: 'Test Metric',
          indicator_short_name: 'TM',
          contents: '10',
          creator: 1,
          uuid: SecureRandom.uuid
        )

        10.times do |i|
          CohortDrillDown.create!(
            reporting_report_design_resource_id: value.id,
            patient_id: 1000 + i
          )
        end

        # Verify count after each iteration
        expect(CohortDrillDown.count).to eq(10),
                                         "After iteration #{iteration + 1}, expected 10 drill-down records"

        # Check for orphans
        orphaned_count = ActiveRecord::Base.connection.select_value(<<~SQL)
          SELECT COUNT(*)
          FROM cohort_drill_down c
          LEFT JOIN reporting_report_design_resource r#{' '}
            ON c.reporting_report_design_resource_id = r.id
          WHERE r.id IS NULL
        SQL

        expect(orphaned_count).to eq(0),
                                  "After iteration #{iteration + 1}, found #{orphaned_count} orphaned records"

        # Destroy report to simulate regeneration
        report.destroy unless iteration == 2 # Keep last one
      end

      # Final verification - should still have only 10 records
      expect(CohortDrillDown.count).to eq(10)
      expect(ReportValue.count).to eq(1)
      expect(Report.count).to eq(1)
    end
  end
end
