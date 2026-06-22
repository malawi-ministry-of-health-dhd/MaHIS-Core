# frozen_string_literal: true

require 'date'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/hash/keys'
require_relative '../../../app/services/hts_service/dashboard'

# These specs cover the pagination/contract logic that backs the lazily-loaded
# dashboard card lists. They intentionally avoid the database (empty / unknown
# inputs short-circuit before any SQL runs), mirroring the standalone style of
# spec/services/facility_referral_service_spec.rb so they run under
# `--require spec_helper` without booting Rails.
RSpec.describe HtsService::Dashboard do
  describe '.build_patient_rows_paginated' do
    it 'returns the documented empty-page shape when there are no patient ids' do
      result = described_class.build_patient_rows_paginated([])

      expect(result[:data]).to eq([])
      expect(result[:pagination]).to eq(
        current_page: 1,
        per_page: described_class::DEFAULT_PATIENT_ROWS_PER_PAGE,
        total_count: 0,
        total_pages: 0
      )
    end

    it 'rejects blank and zero ids and short-circuits to an empty page' do
      result = described_class.build_patient_rows_paginated([nil, 0, '0', ''])

      expect(result[:data]).to be_empty
      expect(result[:pagination][:total_count]).to eq(0)
    end

    it 'echoes the requested page and per_page in the empty-page metadata' do
      result = described_class.build_patient_rows_paginated([], page: 3, per_page: 25)

      expect(result[:pagination][:current_page]).to eq(3)
      expect(result[:pagination][:per_page]).to eq(25)
    end

    it 'normalises out-of-range page and per_page values' do
      result = described_class.build_patient_rows_paginated([], page: -4, per_page: 0)

      expect(result[:pagination][:current_page]).to eq(1)
      expect(result[:pagination][:per_page]).to eq(described_class::DEFAULT_PATIENT_ROWS_PER_PAGE)
    end
  end

  describe '.dashboard_patients' do
    it 'returns an empty page for an unknown category without touching the database' do
      result = described_class.dashboard_patients(category: 'nonsense', date: '2024-01-01')

      expect(result[:data]).to eq([])
      expect(result[:pagination][:total_count]).to eq(0)
    end

    it 'clamps per_page to the 200-row ceiling' do
      result = described_class.dashboard_patients(category: 'nonsense', date: '2024-01-01', per_page: 9999)

      expect(result[:pagination][:per_page]).to eq(200)
    end

    it 'defaults per_page when a non-positive value is supplied' do
      result = described_class.dashboard_patients(category: 'nonsense', date: '2024-01-01', per_page: 0)

      expect(result[:pagination][:per_page]).to eq(described_class::DEFAULT_PATIENT_ROWS_PER_PAGE)
    end

    it 'forces the page number to at least 1' do
      result = described_class.dashboard_patients(category: 'nonsense', date: '2024-01-01', page: 0)

      expect(result[:pagination][:current_page]).to eq(1)
    end
  end
end
