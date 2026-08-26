# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientSyncReconciler do
  describe '.eligible_patient_scope' do
    it 'requires a nonblank permanent Person UUID, not a DDE identifier' do
      sql = described_class.eligible_patient_scope.to_sql

      expect(sql).to include('INNER JOIN `person`')
      expect(sql).to include('person`.`uuid`')
      expect(sql).not_to include('patient_identifier')
    end
  end

  describe '.syncable_patient_count' do
    it 'counts patients with permanent record UUIDs' do
      scope = instance_double(ActiveRecord::Relation)
      allow(described_class).to receive(:eligible_patient_scope).and_return(scope)
      expect(scope).to receive(:count).and_return(128_825)

      expect(described_class.syncable_patient_count).to eq(128_825)
    end
  end

  describe '.eligible_patient_ids' do
    it 'selects patient IDs from the UUID-addressable patient scope' do
      sql = described_class.eligible_patient_ids.to_sql

      expect(sql).to include('patient`.`patient_id')
      expect(sql).to include('person`.`uuid`')
    end
  end
end
