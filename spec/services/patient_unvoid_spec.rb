# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PatientService, 'void and restore' do
  subject(:service) { described_class.new }

  let(:user) { User.unscoped.first }

  before do
    # The restore rebuilds the patient's CouchDB document; there is no CouchDB
    # behind the test suite.
    allow(BuildPatientRecordService).to receive(:build_patient_record).and_return({ 'ID' => 'rebuilt' })
    allow(CouchdbPatientService).to receive(:sync_patient_to_couchdb).and_return({ success: true })
    allow(DdeService).to receive(:dde_enabled?).and_return(false)
    @patient_ids = []
  end

  after do
    @patient_ids.each { |patient_id| purge_patient(patient_id) }
  end

  def build_patient(family_name: 'last')
    patient = create(:patient)
    @patient_ids << patient.patient_id
    person = Person.unscoped.find(patient.patient_id)
    create(:person_name, person:, family_name:)
    encounter = create(:encounter, patient:)
    [patient, person, encounter]
  end

  def purge_patient(patient_id)
    Observation.unscoped.where(person_id: patient_id).delete_all
    Order.unscoped.where(patient_id: patient_id).delete_all
    Encounter.unscoped.where(patient_id: patient_id).delete_all
    PatientIdentifier.unscoped.where(patient_id: patient_id).delete_all
    PatientVoidBatch.where(patient_id: patient_id).delete_all
    Patient.unscoped.where(patient_id: patient_id).delete_all
    PersonName.unscoped.where(person_id: patient_id).delete_all
    Person.unscoped.where(person_id: patient_id).delete_all
  end

  it 'tags every voided row with the batch marker and leaves earlier retractions alone' do
    patient, person, encounter = build_patient
    kept = create(:observation, person:, encounter:)
    retracted = create(:observation, person:, encounter:)
    retracted.void('Wrong entry corrected by clinician')

    batch = service.void_patient(patient, 'Duplicate', daemonize: false)

    expect(batch.tagged_reason).to eq("[PV:#{batch.id}] Duplicate")
    expect(Patient.unscoped.find(patient.patient_id).void_reason).to eq(batch.tagged_reason)
    expect(Observation.unscoped.find(kept.obs_id).void_reason).to eq(batch.tagged_reason)
    expect(batch.row_counts['obs']).to eq(1)
    expect(batch.row_counts['patient']).to eq(1)

    # The clinician's own retraction keeps its reason: VoidableRecord's default
    # scope excludes rows that were already voided.
    expect(Observation.unscoped.find(retracted.obs_id).void_reason).to eq('Wrong entry corrected by clinician')
  end

  it 'previews what a restore would bring back' do
    patient, person, encounter = build_patient
    create(:observation, person:, encounter:)
    create(:observation, person:, encounter:).void('Duplicate vitals')

    service.void_patient(patient, 'Voided the wrong client', daemonize: false)
    preview = service.void_restore_preview(patient.patient_id)

    expect(preview[:exact]).to be(true)
    expect(preview[:restorable]['obs']).to eq(1)
    expect(preview[:restorable]['encounter']).to eq(1)
    expect(preview[:already_voided_count]).to eq(1)
  end

  it 'restores exactly the rows the void voided' do
    patient, person, encounter = build_patient
    kept = create(:observation, person:, encounter:)
    retracted = create(:observation, person:, encounter:)
    retracted.void('Wrong entry corrected by clinician')

    batch = service.void_patient(patient, 'Duplicate', daemonize: false)
    result = service.unvoid_patient(patient.patient_id, 'Voided in error')

    # Default-scoped lookups find them again, so they are live.
    expect(Patient.find_by(patient_id: patient.patient_id)).to be_present
    expect(Person.find_by(person_id: patient.patient_id)).to be_present
    expect(PersonName.find_by(person_id: patient.patient_id)).to be_present
    expect(Encounter.find_by(encounter_id: encounter.encounter_id)).to be_present
    expect(Observation.find_by(obs_id: kept.obs_id)).to be_present

    # The clinical retraction stays retracted, with its own reason intact.
    expect(Observation.find_by(obs_id: retracted.obs_id)).to be_nil
    expect(Observation.unscoped.find(retracted.obs_id).void_reason).to eq('Wrong entry corrected by clinician')

    expect(result[:row_counts]['obs']).to eq(1)
    expect(result[:void_batch_id]).to eq(batch.id)
    expect(batch.reload).to be_restored
    expect(batch.restore_reason).to eq('Voided in error')

    restored = Patient.unscoped.find(patient.patient_id)
    expect(restored.date_voided).to be_nil
    expect(restored.voided_by).to be_nil
    expect(restored.void_reason).to be_nil
  end

  it 'rebuilds the CouchDB document the void deleted' do
    patient, person, encounter = build_patient
    create(:observation, person:, encounter:)
    service.void_patient(patient, 'Duplicate', daemonize: false)

    result = service.unvoid_patient(patient.patient_id, 'Voided in error')

    expect(BuildPatientRecordService).to have_received(:build_patient_record).with(patient.patient_id)
    expect(CouchdbPatientService).to have_received(:sync_patient_to_couchdb)
      .with({ 'ID' => 'rebuilt' }, patient.patient_id)
    expect(result[:couchdb_restored]).to be(true)
  end

  it 'restores a patient voided before batches were recorded' do
    patient, person, encounter = build_patient
    kept = create(:observation, person:, encounter:)
    retracted = create(:observation, person:, encounter:)
    retracted.void('Wrong entry corrected by clinician')

    # Reproduce a pre-batch void: the same (date_voided, voided_by, void_reason)
    # triple stamped across every table, and no batch row.
    stamp = { voided: 1, date_voided: Time.current.change(usec: 0), voided_by: user.user_id,
              void_reason: 'Duplicate' }
    [Patient.unscoped.where(patient_id: patient.patient_id),
     Person.unscoped.where(person_id: patient.patient_id),
     PersonName.unscoped.where(person_id: patient.patient_id),
     Encounter.unscoped.where(patient_id: patient.patient_id),
     Observation.unscoped.where(obs_id: kept.obs_id)].each { |scope| scope.update_all(stamp) }

    preview = service.void_restore_preview(patient.patient_id)
    expect(preview[:exact]).to be(false)
    expect(preview[:restorable]['obs']).to eq(1)
    expect(preview[:already_voided_count]).to eq(1)

    result = service.unvoid_patient(patient.patient_id, 'Voided in error')

    expect(Patient.find_by(patient_id: patient.patient_id)).to be_present
    expect(Observation.find_by(obs_id: kept.obs_id)).to be_present
    expect(Observation.find_by(obs_id: retracted.obs_id)).to be_nil
    expect(result[:void_batch_id]).to be_nil
  end

  it 'refuses to restore a patient voided by a merge, and keeps them off the list' do
    patient, = build_patient
    Patient.unscoped.where(patient_id: patient.patient_id)
           .update_all(voided: 1, date_voided: Time.current.change(usec: 0), voided_by: user.user_id,
                       void_reason: 'Merged into patient #12345:0')

    expect { service.unvoid_patient(patient.patient_id, 'Voided in error') }
      .to raise_error(InvalidParameterError, /voided by a merge/)

    expect(service.voided_patients(from: Date.current.to_s)[:patients].map { |entry| entry[:patient_id] })
      .not_to include(patient.patient_id)
  end

  it 'refuses to restore a patient who is not voided' do
    patient, = build_patient

    expect { service.unvoid_patient(patient.patient_id, 'Voided in error') }
      .to raise_error(InvalidParameterError, /not voided/)
  end

  it 'requires a reason' do
    patient, = build_patient
    service.void_patient(patient, 'Duplicate', daemonize: false)

    expect { service.unvoid_patient(patient.patient_id, '  ') }
      .to raise_error(InvalidParameterError, /reason/)
  end

  it 'lists voided patients newest first and filters by void date' do
    patient, = build_patient
    service.void_patient(patient, 'Voided the wrong client', daemonize: false)

    # Date.current, not Date.today: date_voided is stamped in the application's
    # zone (Africa/Blantyre) while Date.today follows the system zone. On a UTC
    # runner after 22:00 those are different days, so the patient voided a line
    # earlier falls outside the very window this filters on.
    listed = service.voided_patients(from: Date.current.to_s, to: Date.current.to_s)
    row = listed[:patients].find { |entry| entry[:patient_id] == patient.patient_id }

    expect(row).to be_present
    # The marker is bookkeeping, so the screen shows only what a human typed.
    expect(row[:void_reason]).to eq('Voided the wrong client')
    expect(row[:void_batch_id]).to be_present

    expect(service.voided_patients(from: (Date.current + 1).to_s)[:patients].map { |entry| entry[:patient_id] })
      .not_to include(patient.patient_id)
  end

  it 'pages through the list and reports the full total' do
    # A family name unique to this example, so the total is not affected by
    # whatever else the test database already has voided. Letters only:
    # PersonName rejects digits.
    family_name = "Pagetest#{('a'..'z').to_a.sample(8).join}"
    3.times do
      patient, = build_patient(family_name:)
      service.void_patient(patient, 'Voided the wrong client', daemonize: false)
    end

    first = service.voided_patients(search: family_name, limit: 2, offset: 0)
    expect(first[:total]).to eq(3)
    expect(first[:patients].size).to eq(2)
    expect(first[:limit]).to eq(2)

    second = service.voided_patients(search: family_name, limit: 2, offset: 2)
    expect(second[:total]).to eq(3)
    expect(second[:patients].size).to eq(1)
    expect(second[:offset]).to eq(2)

    # No overlap between the pages.
    ids = (first[:patients] + second[:patients]).map { |entry| entry[:patient_id] }
    expect(ids.uniq.size).to eq(3)
  end

  it 'finds a voided patient by a voided identifier' do
    patient, = build_patient
    identifier = "PGT-#{SecureRandom.hex(4)}"
    PatientIdentifier.create!(patient_id: patient.patient_id, identifier:,
                              identifier_type: PatientIdentifierType.first.patient_identifier_type_id,
                              location_id: Location.current&.location_id, creator: user.user_id)
    service.void_patient(patient, 'Voided the wrong client', daemonize: false)

    found = service.voided_patients(search: identifier)

    expect(found[:total]).to eq(1)
    expect(found[:patients].first[:patient_id]).to eq(patient.patient_id)
  end
end
