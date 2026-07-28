# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientSyncReconciler do
  describe '.eligible_identifier_scope' do
    it 'requires a nonblank, non-voided type-3 identifier on a non-voided patient' do
      sql = described_class.eligible_identifier_scope.to_sql

      expect(sql).to include('patient_identifier`.`identifier_type` = 3')
      expect(sql).to include('patient_identifier`.`voided` = 0')
      expect(sql).to include('NOT ((')
      expect(sql).to include('patient_identifier`.`identifier` =')
      expect(sql).to include('patient_identifier`.`identifier` IS NULL')
      expect(sql).to include('patient.voided = 0')
    end
  end

  describe '.distinct_primary_identifier_count' do
    it 'counts distinct document identifiers from the canonical identifier scope' do
      scope = instance_double(ActiveRecord::Relation)
      distinct_scope = instance_double(ActiveRecord::Relation)
      allow(described_class).to receive(:canonical_identifier_scope).and_return(scope)
      expect(scope).to receive(:distinct).and_return(distinct_scope)
      expect(distinct_scope).to receive(:count)
        .with('patient_identifier.identifier')
        .and_return(128_825)

      expect(described_class.distinct_primary_identifier_count).to eq(128_825)
    end
  end

  describe '.canonical_identifier_scope' do
    it 'selects only the newest valid type-3 identifier per patient' do
      sql = described_class.canonical_identifier_scope.to_sql

      expect(sql).to include('NOT EXISTS')
      expect(sql).to include('newer.patient_id = patient_identifier.patient_id')
      expect(sql).to include('newer.date_created')
      expect(sql).to include('newer.patient_identifier_id > patient_identifier.patient_identifier_id')
    end
  end
end
