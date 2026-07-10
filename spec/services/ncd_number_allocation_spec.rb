# frozen_string_literal: true

require 'rails_helper'

# Covers the NCD number allocation/uniqueness rules:
#   - gap-filling next-available computation
#   - voided identifiers are never reused
#   - concurrent-save collision is resolved by re-assigning the next free number
#
# NOTE: needs the test DB provisioned (schema + seeds). Each example runs inside a
# transaction that is rolled back, so no data leaks between examples.
RSpec.describe 'NCD number allocation', type: :model do
  NCD_TYPE_ID = 31
  SITE_PREFIX = 'TEST'

  around(:each) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  before(:each) do
    PatientIdentifierType.find_or_create_by!(patient_identifier_type_id: NCD_TYPE_ID) do |t|
      t.name = 'NCD Number'
      t.creator = 1
      t.date_created = Time.now
      t.uuid = SecureRandom.uuid
    end
    set_global_property('site_prefix', SITE_PREFIX)
    set_global_property('ncd_number_range', '1000')
  end

  def set_global_property(property, value)
    gp = GlobalProperty.find_or_initialize_by(property: property)
    gp.property_value = value
    gp.uuid ||= SecureRandom.uuid
    gp.save!
  end

  def create_ncd_identifier_row(number, voided: 0, patient: nil)
    patient ||= create(:patient)
    create(:patient_identifier,
           patient: patient,
           identifier: "#{SITE_PREFIX}-NCD-#{number}",
           identifier_type: NCD_TYPE_ID,
           voided: voided,
           creator: 1,
           date_created: Time.now,
           uuid: SecureRandom.uuid)
  end

  describe 'PatientIdentifier.next_available_ncd_number' do
    it 'starts at 1 when no NCD numbers exist' do
      expect(PatientIdentifier.next_available_ncd_number(SITE_PREFIX)).to eq(1)
    end

    it 'returns the next number after a contiguous run' do
      [1, 2, 3].each { |n| create_ncd_identifier_row(n) }
      expect(PatientIdentifier.next_available_ncd_number(SITE_PREFIX)).to eq(4)
    end

    it 'fills the lowest gap' do
      create_ncd_identifier_row(1)
      create_ncd_identifier_row(3)
      expect(PatientIdentifier.next_available_ncd_number(SITE_PREFIX)).to eq(2)
    end

    it 'does NOT reuse a voided number' do
      create_ncd_identifier_row(1)
      create_ncd_identifier_row(2, voided: 1) # voided, but must stay reserved
      expect(PatientIdentifier.next_available_ncd_number(SITE_PREFIX)).to eq(3)
    end
  end

  describe 'NcdService::PatientsEngine#ncd_number_already_exists' do
    let(:engine) { NcdService::PatientsEngine.new(program: Program.find_by(name: 'NCD PROGRAM')) }

    it 'is true for an active number' do
      create_ncd_identifier_row(5)
      expect(engine.ncd_number_already_exists("#{SITE_PREFIX}-NCD-5")).to be(true)
    end

    it 'is true even when the only holder is voided (never reused)' do
      create_ncd_identifier_row(6, voided: 1)
      expect(engine.ncd_number_already_exists("#{SITE_PREFIX}-NCD-6")).to be(true)
    end

    it 'is false for an unused number' do
      expect(engine.ncd_number_already_exists("#{SITE_PREFIX}-NCD-999")).to be(false)
    end
  end

  describe 'PatientIdentityManager#create_ncd_identifier (assign + update)' do
    let(:manager) { PatientRecordService::PatientIdentityManager.new }

    def active_numbers(patient)
      PatientIdentifier.where(patient_id: patient.patient_id, identifier_type: NCD_TYPE_ID).pluck(:identifier)
    end

    it 're-assigns the next free number when the requested one is already taken' do
      other_patient = create(:patient)
      create_ncd_identifier_row(1, patient: other_patient) # TEST-NCD-1 already used

      new_patient = create(:patient)
      record = { NcdID: "#{SITE_PREFIX}-NCD-1", unsavedNcdID: "#{SITE_PREFIX}-NCD-1", location_id: Location.current.id }

      manager.create_ncd_identifier(new_patient.patient_id, record)

      expect(active_numbers(new_patient)).to eq(["#{SITE_PREFIX}-NCD-2"]) # re-resolved, not the taken -1
      expect(record[:NcdID]).to eq("#{SITE_PREFIX}-NCD-2")
    end

    it 'updates to a new number and voids the old one' do
      patient = create(:patient)
      create_ncd_identifier_row(1, patient: patient) # existing TEST-NCD-1

      record = { NcdID: "#{SITE_PREFIX}-NCD-5", unsavedNcdID: "#{SITE_PREFIX}-NCD-5", location_id: Location.current.id }
      manager.create_ncd_identifier(patient.patient_id, record)

      voided = PatientIdentifier.unscoped
                                .where(patient_id: patient.patient_id, identifier_type: NCD_TYPE_ID, voided: 1)
                                .pluck(:identifier)
      expect(active_numbers(patient)).to eq(["#{SITE_PREFIX}-NCD-5"])
      expect(voided).to include("#{SITE_PREFIX}-NCD-1")
      expect(record[:NcdID]).to eq("#{SITE_PREFIX}-NCD-5")
    end

    it 'is idempotent when the same number is re-saved' do
      patient = create(:patient)
      create_ncd_identifier_row(3, patient: patient)

      record = { NcdID: "#{SITE_PREFIX}-NCD-3", unsavedNcdID: "#{SITE_PREFIX}-NCD-3", location_id: Location.current.id }
      manager.create_ncd_identifier(patient.patient_id, record)

      expect(active_numbers(patient)).to eq(["#{SITE_PREFIX}-NCD-3"])
    end

    it 're-resolves an update when the target number belongs to another patient' do
      other_patient = create(:patient)
      create_ncd_identifier_row(5, patient: other_patient) # TEST-NCD-5 taken by someone else

      patient = create(:patient)
      create_ncd_identifier_row(1, patient: patient) # currently TEST-NCD-1

      record = { NcdID: "#{SITE_PREFIX}-NCD-5", unsavedNcdID: "#{SITE_PREFIX}-NCD-5", location_id: Location.current.id }
      manager.create_ncd_identifier(patient.patient_id, record)

      # 1 (being voided for this patient) and 5 (other patient) are excluded → 2.
      expect(active_numbers(patient)).to eq(["#{SITE_PREFIX}-NCD-2"])
      expect(record[:NcdID]).to eq("#{SITE_PREFIX}-NCD-2")
    end
  end
end
