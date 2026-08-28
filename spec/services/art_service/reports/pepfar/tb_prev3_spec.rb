# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ArtService::Reports::Pepfar::TbPrev3, type: :service do
  let(:start_date) { Date.today - 3.months }
  let(:end_date) { Date.today }
  let(:report) { ArtService::Reports::Pepfar::TbPrev3.new(start_date:, end_date:) }

  let(:patient_hash) do
    {
      'patient_id' => 1,
      'arv_number' => 'MPC-ARV-1',
      'tpt_initiation_date' => Date.today - 1.month,
      'art_start_date' => Date.today - 2.months,
      'outcome' => 'Active',
      'gender' => 'F',
      'birthdate' => 17.years.ago.to_date,
      'age_group' => '15-19 years',
      'transfer_in' => 0,
      'total_pills_taken' => 30,
      'months_on_tpt' => 1,
      'total_days_on_medication' => 30,
      'drug_concepts' => '123,456'
    }
  end

  describe :new do
    it 'initializes with start and end dates' do
      expect(report).to be_a(ArtService::Reports::Pepfar::TbPrev3)
    end
  end

  describe :check_date do
    it 'return a date 6 months before the start date' do
      expect(report.check_date).to eq(start_date - 6.months)
    end
  end

  describe :find_report do
    it 'returns a report' do
      allow(report).to receive(:patients_on_tpt).and_return([patient_hash])
      expect(report.find_report).to be_a(Hash)
    end
  end

  describe :find_report do
    it 'the response should have 15-19 years group' do
      allow(report).to receive(:patients_on_tpt).and_return([patient_hash])
      expect(report.find_report).to have_key('15-19 years')
    end
  end

  describe :find_report do
    it 'the response should have a hash for 15-19 years group' do
      allow(report).to receive(:patients_on_tpt).and_return([patient_hash])
      expect(report.find_report['15-19 years']).to be_a(Hash)
    end
  end

  describe :find_report do
    it 'should have a key a key female in the 15-19 years group' do
      allow(report).to receive(:patients_on_tpt).and_return([patient_hash])
      expect(report.find_report['15-19 years']).to have_key('F')
    end
  end

  describe :find_report do
    it 'should have started_new_on_art under the female key in the 15-19 years group' do
      allow(report).to receive(:patients_on_tpt).and_return([patient_hash])
      expect(report.find_report['15-19 years']['F']['3HP']).to have_key(:started_new_on_art)
    end
  end

  describe :find_report do
    it 'should have the patient id under the started_new_on_art key in the 15-19 years group' do
      allow(report).to receive(:patients_on_tpt).and_return([patient_hash])
      result = report.find_report
      expect(result['15-19 years']['F']['3HP'][:started_new_on_art]).to include(hash_including('patient_id' => 1))
    end
  end

  describe :patient_tpt_status do
    it 'returns a patient tpt status' do
      allow(report).to receive(:individual_tpt_report).and_return(
        'tpt_initiation_date' => Date.today - 1.month,
        'total_pills_taken' => 30,
        'months_on_tpt' => 1,
        'total_days_on_medication' => 30,
        'drug_concepts' => '123,456',
        'transfer_in' => 0
      )
      expect(report.patient_tpt_status(1)).to be_a(Hash)
    end
  end
end
