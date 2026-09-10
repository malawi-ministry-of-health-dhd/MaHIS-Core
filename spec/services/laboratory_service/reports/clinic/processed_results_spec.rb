# frozen_string_literal: true

# These query-construction tests do not boot Rails or require a database.
require 'spec_helper'
require 'active_record'
require 'active_support/all'
require_relative '../../../../../app/utils/common_sql_query_utils'
require_relative '../../../../../app/services/laboratory_service/reports/clinic/processed_results'

RSpec.describe LaboratoryService::Reports::Clinic::ProcessedResults do
  let(:connection) { double('report connection') }
  let(:options) { {} }
  let(:report) { described_class.new(start_date: '2026-01-01', end_date: '2026-04-02', **options) }
  let(:rows) { [] }

  before do
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    allow(connection).to receive(:quote) { |value| "'#{value.iso8601}'" }
    allow(connection).to receive(:select_all) do |sql|
      @sql = sql
      rows
    end
  end

  describe '#read' do
    it 'uses three targeted deterministic name lookups instead of dictionary-wide grouping' do
      report.read

      expect(@sql).not_to match(/GROUP BY (?:cn\.)?concept_id/)
      %w[orders.concept_id reason_for_test_obs.value_coded measure.concept_id].each do |column|
        expect(@sql).to include("WHERE cn.concept_id = #{column}")
      end
      expect(@sql.scan('ORDER BY cn.concept_name_id').length).to eq(3)
      expect(@sql.scan('LIMIT 1').length).to eq(3)
      expect(@sql.scan('c.retired = 0').length).to eq(3)
      expect(@sql).not_to include('cn.locale', 'cn.voided')
    end

    it 'retains order-level grouping and the inclusive end-date range' do
      report.read

      expect(@sql).to include('GROUP BY orders.order_id')
      expect(@sql).to include("lab_result_obs.obs_datetime >= DATE('2026-01-01')")
      expect(@sql).to include("lab_result_obs.obs_datetime < DATE('2026-04-02') + INTERVAL 1 DAY")
      expect(@sql).not_to include('AND lab_result_obs.concept_id IN')
    end

    it 'retains the optional reason name and excludes result metadata only from measure names' do
      report.read

      expect(@sql).to include('LEFT JOIN concept_name AS reason_for_test')
      expect(@sql).to include('COALESCE(reason_for_test.name, reason_for_test_obs.value_text)')
      expect(@sql.scan("cn.name NOT LIKE 'Lab test result'").length).to eq(1)
      expect(@sql.scan("cn.name NOT LIKE 'Lab Test Status'").length).to eq(1)
      measure_lookup = @sql.split('INNER JOIN concept_name AS measure_concept').last
      expect(measure_lookup).to include("cn.name NOT LIKE 'Lab test result'", "cn.name NOT LIKE 'Lab Test Status'")
    end

    [nil, '', 'All', 'Other'].each do |occupation|
      context "with occupation #{occupation.inspect}" do
        let(:options) { { occupation: occupation } }

        it 'does not fetch or join occupation attributes when there is no supported filter' do
          expect(report).not_to receive(:current_occupation_query)
          report.read

          expect(@sql).not_to include('person_attribute', 'AS a ON', 'a.value')
        end
      end
    end

    %w[Military Civilian].each do |occupation|
      context "with occupation #{occupation}" do
        let(:options) { { occupation: occupation } }

        it 'keeps the occupation join and the existing filter' do
          expect(report).to receive(:current_occupation_query).once
            .and_return('SELECT person_id, value FROM person_attribute')
          report.read

          expect(@sql).to include('LEFT JOIN (SELECT person_id, value FROM person_attribute) AS a')
          operator = occupation == 'Military' ? 'IN' : 'NOT IN'
          expect(@sql).to include("AND a.value #{operator} ('Military', 'MDF Reserve', 'MDF Retired', 'Soldier', 'Soldier/Police')")
        end
      end
    end

    context 'with DSD filtering' do
      let(:options) { { dsd: '123' } }

      it 'retains the existing DSD joins' do
        report.read

        expect(@sql).to include('INNER JOIN patient_program pp ON pp.patient_id = orders.patient_id')
        expect(@sql).to include('INNER JOIN patient_state ps', 'AND concept_id = 123')
      end
    end

    context 'with a result row' do
      let(:rows) do
        [{
          'accession_number' => 'sample-1', 'result_id' => 1, 'result_date' => '2026-01-02',
          'patient_id' => 2, 'order_date' => '2026-01-01', 'test' => 'Blood', 'gender' => 'F',
          'reason_for_test' => 'Routine', 'reason_for_test_obs_id' => 3, 'arv_number' => 'ART-1',
          'birthdate' => '1990-01-01', 'age_group' => '35-39 years',
          'measures' => 'HIV Viral load:=:100,CD4 count:<:200'
        }]
      end

      it 'preserves the response fields and measure parsing' do
        expected = rows.first.except('measures').transform_keys(&:to_sym).merge(
          measures: [{ name: 'HIV Viral load', modifier: '=', value: '100' },
                     { name: 'CD4 count', modifier: '<', value: '200' }]
        )
        expect(report.read).to eq([expected])
      end
    end

    it 'returns an empty array for no results' do
      expect(report.read).to eq([])
    end
  end
end