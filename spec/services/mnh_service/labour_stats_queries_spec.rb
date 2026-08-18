# frozen_string_literal: true

require 'rails_helper'

# Covers the shape of the Labour stats payload, which the MaHIS dashboard maps
# field-by-field. Two real bugs motivated this spec:
#
#   1. #obstetric_complication_percentages used to bail out with {} when there
#      were no labour mothers, so the payload silently lost every
#      `obstetric_complication_*_percentage` key. The client read the missing
#      `..._none_percentage` as 0 and rendered "100% with obstetric
#      complication" on a completely empty dataset.
#   2. The condition keys are derived from OBSTETRIC_COMPLICATION_CONDITIONS via
#      #condition_key, so renaming a condition silently renames a payload key
#      and the matching dashboard card goes permanently blank.
#
# NOTE: needs the test DB provisioned (schema + seeds). Each example runs inside
# a transaction that is rolled back, so no data leaks between examples.
RSpec.describe MnhService::LabourStatsQueries, type: :service do
  # A location of its own keeps the "empty dataset" assertions true even when
  # the test DB carries seeded encounters for other facilities.
  let(:location) do
    Location.create!(name: "Labour Stats Spec Facility #{SecureRandom.hex(4)}",
                     creator: 1,
                     date_created: Time.now,
                     uuid: SecureRandom.uuid)
  end

  let(:program) { find_or_create_program('LABOUR PROGRAM') }

  subject(:stats) { described_class.new(program.id, location_id: location.location_id).stats_hash }

  around(:each) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  before(:each) do
    # ConceptCache is process-wide and caches hits only, so concepts created in
    # a rolled-back transaction would leak stale ids into later examples.
    MnhService::ConceptCache.reset!
    find_or_create_concept('Obstetric complications')
    find_or_create_concept('referral reasons')
    described_class::OBSTETRIC_COMPLICATION_CONDITIONS.each { |name| find_or_create_concept(name) }
  end

  after(:each) { MnhService::ConceptCache.reset! }

  describe '#stats_hash with no recorded data' do
    it 'reports zero labour mothers' do
      expect(stats[:total_labour_mothers]).to eq(0)
    end

    it 'still emits every obstetric complication percentage key, zeroed' do
      described_class::OBSTETRIC_COMPLICATION_CONDITIONS.each do |condition|
        key = :"obstetric_complication_#{condition.downcase.gsub(/[^a-z0-9]+/, '_')}_percentage"

        expect(stats).to have_key(key)
        expect(stats[key]).to eq(0.0)
      end
    end

    it 'reports 0.0 for the "none" percentage rather than omitting it' do
      # The client derives "% with a complication" against this value; a missing
      # key read as 0 produced a bogus 100%.
      expect(stats[:obstetric_complication_none_percentage]).to eq(0.0)
    end

    it 'zeroes every top-level percentage' do
      expect(stats).to include(
        percentage_delivered_by_skilled_attendants: 0.0,
        percentage_delivered_at_this_facility: 0.0,
        percentage_caesarean_section: 0.0
      )
    end

    it 'emits a referral entry per condition, zeroed' do
      expect(stats[:referral_by_condition].map { |r| r[:label] })
        .to eq(described_class::REFERRAL_REASON_OPTIONS.map { |o| o[:label] })
      expect(stats[:referral_by_condition].map { |r| r[:percentage] }).to all(eq(0.0))
    end
  end

  describe 'payload key names' do
    # These are the exact keys src/apps/LABOUR/services/labour_dashboard_service.ts
    # reads. A rename here blanks a dashboard card with no error anywhere.
    expected_keys = %i[
      obstetric_complication_none_percentage
      obstetric_complication_postpartum_haemorrhage_percentage
      obstetric_complication_pre_eclampsia_percentage
      obstetric_complication_eclampsia_percentage
      obstetric_complication_sepsis_percentage
      obstetric_complication_retained_placenta_percentage
      obstetric_complication_perineal_tear_percentage
      obstetric_complication_other_percentage
    ]

    expected_keys.each do |key|
      it "includes #{key}" do
        expect(stats).to have_key(key)
      end
    end

    it 'pairs every percentage key with a count key' do
      expected_keys.each do |percentage_key|
        expect(stats).to have_key(percentage_key.to_s.sub(/_percentage\z/, '_count').to_sym)
      end
    end
  end

  def find_or_create_program(name)
    Program.unscoped.where(Program.arel_table[:name].lower.eq(name.downcase)).first ||
      create(:program, name: name)
  end

  def find_or_create_concept(name)
    existing = ConceptName.unscoped.find_by(name: name)
    return Concept.unscoped.find(existing.concept_id) if existing

    concept = create(:concept)
    create(:concept_name, concept: concept, name: name)
    concept
  end
end
