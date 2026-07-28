# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VoidUnsyncablePatientsTask do
  describe 'candidate scopes' do
    subject(:task) { described_class.new({}) }

    it 'requires no valid type-3 identifier and no program row' do
      sql = task.send(:base_scope).to_sql

      expect(sql).to include('`patient`.`voided` = 0')
      expect(sql).to include('cleanup_identifier.identifier_type = 3')
      expect(sql).to include('cleanup_identifier.voided = 0')
      expect(sql).to include("cleanup_identifier.identifier <> ''")
      expect(sql).to include('cleanup_program.patient_id = patient.patient_id')
    end

    it 'protects patients with any encounter, observation, or order by default' do
      sql = task.send(:safe_scope).to_sql

      expect(sql).to include('cleanup_encounter.patient_id = patient.patient_id')
      expect(sql).to include('cleanup_observation.person_id = patient.patient_id')
      expect(sql).to include('cleanup_order.patient_id = patient.patient_id')
    end
  end

  describe 'confirmation' do
    it 'requires a stronger phrase when clinical patients are included' do
      expect do
        described_class.new(
          'APPLY' => '1',
          'INCLUDE_CLINICAL' => '1',
          'CONFIRM' => described_class::SAFE_CONFIRMATION,
          'VOIDED_BY' => '1'
        )
      end.to raise_error(/CONFIRM=VOID_PATIENTS_WITH_CLINICAL_DATA/)
    end
  end
end
