# frozen_string_literal: true

require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/filters'
require_relative '../../app/services/facility_referral_service'

RSpec.describe FacilityReferralService do
  describe '#base_referral_sql' do
    subject(:sql) { described_class.new.send(:base_referral_sql, {}) }

    it 'excludes referrals that already have an encounter at the referred facility' do
      expect(sql).to include('NOT EXISTS')
      expect(sql).to include('referred_facility_encounter.patient_id = e.patient_id')
      expect(sql).to include('referred_facility_encounter.encounter_datetime > e.encounter_datetime')
      expect(sql).to include('referred_facility_encounter_obs.encounter_id = referred_facility_encounter.encounter_id')
      expect(sql).to include('CAST(referred_facility_encounter_obs.location_id AS UNSIGNED) = COALESCE')
    end
  end
end
