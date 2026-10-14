# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtService::Reports::RegimenDispensationData do
  describe '#create_temp_current_dispensation' do
    it 'limits the dispensation cohort to the requested report period' do
      report = described_class.allocate
      report.instance_variable_set(:@start_date, "'2026-01-01 00:00:00'")
      report.instance_variable_set(:@end_date, "'2026-01-31 23:59:59'")
      report.instance_variable_set(:@location_id, 58)
      report.instance_variable_set(:@occupation, nil)
      report.instance_variable_set(:@dsd, nil)
      report.instance_variable_set(:@drug_order_type_id, 1)
      allow(report).to receive(:current_occupation_query).and_return('SELECT person_id, value FROM person_attribute')

      expect(report).to receive(:create_indexed_temp_table) do |_table, _index, _columns, sql|
        expect(sql).to include("o.start_date > '2026-01-31 23:59:59' - INTERVAL 18 MONTH")
        expect(sql).to include(
          "o.start_date BETWEEN '2026-01-01 00:00:00' AND '2026-01-31 23:59:59'"
        )
        expect(sql).to include('e.location_id = 58')
      end

      report.send(:create_temp_current_dispensation)
    end
  end

  describe '#create_indexed_temp_table' do
    it 'creates the index after loading rows' do
      report = described_class.allocate
      connection = ActiveRecord::Base.connection

      expect(connection).to receive(:execute).ordered do |sql|
        expect(sql).to include('CREATE TABLE report_rows SELECT patient_id FROM patients')
      end
      expect(connection).to receive(:execute).ordered do |sql|
        expect(sql).to include('CREATE INDEX report_rows_patient_id ON report_rows (patient_id)')
      end

      report.send(:create_indexed_temp_table, 'report_rows', 'report_rows_patient_id', 'patient_id',
                  'SELECT patient_id FROM patients')
    end
  end

  describe '#create_temp_patient_start_date' do
    it 'calculates ART start date only for on-treatment patients without unused enrollment joins' do
      report = described_class.allocate
      report.instance_variable_set(:@end_date, "'2026-01-31 23:59:59'")
      report.instance_variable_set(:@hiv_program_id, 1)
      report.instance_variable_set(:@on_arv_state_id, 7)
      report.instance_variable_set(:@dsd, nil)
      allow(report).to receive(:temp_reg_outcome).and_return('temp_reg_outcome_test')

      expect(report).to receive(:create_indexed_temp_table) do |_table, _index, _columns, sql|
        expect(sql).to include('date_antiretrovirals_started(p.patient_id, MIN(s.start_date))')
        expect(sql).to include('INNER JOIN patient_state s')
        expect(sql).to include(
          "p.patient_id IN (SELECT patient_id FROM temp_reg_outcome_test WHERE outcome = 'On antiretrovirals')"
        )
        expect(sql).not_to include('patient_date_enrolled')
        expect(sql).not_to include('JOIN person')
      end

      report.send(:create_temp_patient_start_date)
    end
  end

  describe '#create_temp_regimen_patient_weight' do
    it 'uses the Weight (kg) concept for the latest observation before the report end date' do
      report = described_class.allocate
      report.instance_variable_set(:@end_date, "'2026-01-31 23:59:59'")
      allow(report).to receive_messages(temp_reg_outcome: 'temp_reg_outcome_test',
                                        temp_regimen_patient_weight: 'temp_regimen_patient_weight_test',
                                        idx_patient_weight: 'idx_patient_weight_test',
                                        concept_name_to_id: 53_325)

      expect(report).to receive(:create_indexed_temp_table) do |table, index, columns, sql|
        expect([table, index, columns]).to eq(
          ['temp_regimen_patient_weight_test', 'idx_patient_weight_test', 'patient_id']
        )
        expect(sql.scan('concept_id = 53325').length).to eq(2)
        expect(sql).to include("o.obs_datetime < '2026-01-31 23:59:59' + INTERVAL 1 DAY")
        expect(sql).to include("WHERE tro.outcome = 'On antiretrovirals'")
      end

      report.send(:create_temp_regimen_patient_weight)
    end

    it 'raises when the Weight (kg) concept is missing' do
      report = described_class.allocate
      allow(report).to receive(:concept_name_to_id).with('Weight (kg)').and_return(nil)

      expect { report.send(:create_temp_regimen_patient_weight) }
        .to raise_error(ActiveRecord::RecordNotFound, "Concept 'Weight (kg)' was not found")
    end
  end

  describe '#create_temp_vl_result' do
    it 'builds cohort-filtered candidates before joining concept names' do
      report = described_class.allocate
      report.instance_variable_set(:@end_date, "'2026-10-12 23:59:59'")
      report.instance_variable_set(:@location_id, 58)
      allow(report).to receive_messages(temp_reg_outcome: 'temp_reg_outcome_test',
                                        temp_vl_results: 'temp_vl_results_test',
                                        idx_vl_result: 'idx_vl_result_test',
                                        temp_vl_result_candidates: 'temp_vl_result_candidates_test',
                                        idx_vl_result_candidates: 'idx_vl_result_candidates_test')

      expect(report).to receive(:create_indexed_temp_table).ordered do |table, index, columns, sql|
        expect([table, index, columns]).to eq(
          ['temp_vl_result_candidates_test', 'idx_vl_result_candidates_test', 'concept_id']
        )
        expect(sql).to match(
          /SELECT DISTINCT patient_id\s+FROM temp_reg_outcome_test\s+WHERE outcome = 'On antiretrovirals'/
        )
        expect(sql).to include('measure.person_id = on_treatment.patient_id')
        expect(sql).to include('measure.obs_group_id IS NOT NULL')
        expect(sql).to include('measure.value_numeric IS NOT NULL || measure.value_text IS NOT NULL')
        expect(sql).to include('e.location_id = 58')
        expect(sql).to include('lab_result_obs.obs_datetime < \'2026-10-12 23:59:59\' + INTERVAL 1 DAY')
      end
      expect(report).to receive(:create_indexed_temp_table).ordered do |table, index, columns, sql|
        expect([table, index, columns]).to eq(
          ['temp_vl_results_test', 'idx_vl_result_test', 'patient_id, result_date']
        )
        expect(sql).to include('candidate.concept_id')
        expect(sql).to include('candidate.result_date, candidate.result, candidate.patient_id')
        expect(sql).not_to include('INNER JOIN orders')
        expect(sql).not_to include('INNER JOIN encounter')
        expect(sql).to include('measure_concept ON measure_concept.concept_id = candidate.concept_id')
      end

      report.send(:create_temp_vl_result)
    end
  end

  describe '#fetch_medications' do
    it 'loads and groups medications for all patients in one query' do
      report = described_class.allocate
      allow(report).to receive(:temp_drug_dispensed).and_return('temp_drug_dispensed_test')
      connection = ActiveRecord::Base.connection

      expect(connection).to receive(:select_all).once do |sql|
        expect(sql).to include('WHERE tdd.patient_id IN (101,202)')
        [
          { 'patient_id' => 101, 'name' => 'Drug A', 'start_date' => '2026-10-01', 'quantity' => 30 },
          { 'patient_id' => 202, 'name' => 'Drug B', 'start_date' => '2026-10-02', 'quantity' => 60 }
        ]
      end

      expect(report.send(:fetch_medications, [101, '202', 101])).to eq(
        101 => [{ medication: 'Drug A', start_date: '2026-10-01', quantity: 30 }],
        202 => [{ medication: 'Drug B', start_date: '2026-10-02', quantity: 60 }]
      )
    end

    it 'does not query when there are no patients' do
      report = described_class.allocate

      expect(ActiveRecord::Base.connection).not_to receive(:select_all)
      expect(report.send(:fetch_medications, [])).to eq({})
    end
  end
end
