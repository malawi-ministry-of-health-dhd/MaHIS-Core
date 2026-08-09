# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DuplicateIdentifierCleanupTask do
  it 'requires explicit confirmation in apply mode' do
    expect do
      described_class.new({ 'APPLY' => '1', 'CONFIRM' => 'REPAIR' })
    end.to raise_error(/CONFIRM=REPAIR_REVIEWED_IDENTIFIER_DUPLICATES/)
  end

  it 'requires a separate DDE confirmation before requesting a type-3 identifier' do
    task = described_class.new({})
    patient = instance_double(Patient)

    expect do
      task.send(:request_fresh_dde!, patient)
    end.to raise_error(/DDE_CONFIRM=REQUEST_FRESH_DDE_IDENTIFIERS/)
  end


  it 'allows no approval file only with the unattended confirmation phrase' do
    expect do
      described_class.new({
        'APPLY' => '1',
        'UNATTENDED' => '1',
        'UNATTENDED_CONFIRM' => described_class::UNATTENDED_CONFIRMATION,
        'CONFIRM' => described_class::CONFIRMATION,
        'USER_ID' => '1'
      })
    end.not_to raise_error
  end

  it 'keeps one DDE reassignment per patient in an unattended batch' do
    task = described_class.new({})
    rows = [
      { 'action' => 'request_fresh_dde', 'target_patient_id' => '10' },
      { 'action' => 'request_fresh_dde', 'target_patient_id' => '10' },
      { 'action' => 'delete_extra_identifier', 'target_patient_id' => '10', 'identifier_type' => '3' },
      { 'action' => 'delete_extra_identifier', 'target_patient_id' => '20', 'identifier_type' => '3' },
      { 'action' => 'assign_reviewed_value', 'target_patient_id' => '30' }
    ]

    expect(task.send(:unattended_batch, rows)).to eq([rows[0], rows[3]])
  end

  it 'records deferred DDE repairs and does not select them again in the same run' do
    task = described_class.new({})
    task.instance_variable_set(:@unattended, true)
    row = {
      'action' => 'request_fresh_dde',
      'target_patient_id' => '335661',
      'target_identifier_row_id' => '99001'
    }
    allow(task).to receive(:apply_row!)
      .and_raise(described_class::DeferredDdeRepair, 'document is not in the local proxy')

    expect(task.send(:apply_rows!, [row])).to eq(0)
    expect(task.send(:unattended_batch, [row])).to be_empty
    expect(task.instance_variable_get(:@deferred_rows).values.first['deferred_reason'])
      .to eq('document is not in the local proxy')
  end

  it 'retains unique historical NPIDs as active type-2 aliases after DDE reassignment' do
    task = described_class.new({})
    patient_id = 91_000_000 + rand(1_000_000)
    user = User.unscoped.first
    location = Location.unscoped.first
    raise 'The test database needs a user and location' unless user && location

    previous_user = User.current
    User.current = user
    ensure_identifier_type(2, 'Old identification number', user.id)
    ensure_identifier_type(3, 'National id', user.id)
    ensure_identifier_type(27, 'DDE person document id', user.id)
    person = Person.create!(person_id: patient_id, gender: 'F', birthdate: Date.new(1990, 1, 1),
                            birthdate_estimated: 0, creator: user.id, uuid: SecureRandom.uuid)
    Patient.create!(patient_id:, creator: user.id)

    old_npid = create_identifier(patient_id, 3, "OLD-#{patient_id}", location.id, user.id)
    create_identifier(patient_id, 2, "OLDER-#{patient_id}", location.id, user.id)
    create_identifier(patient_id, 27, "OLD-DOC-#{patient_id}", location.id, user.id)
    current_npid = create_identifier(patient_id, 3, "NEW-#{patient_id}", location.id, user.id)
    create_identifier(patient_id, 27, "NEW-DOC-#{patient_id}", location.id, user.id)

    previous = [
      { identifier: old_npid.identifier, identifier_type: 3, location_id: location.id },
      { identifier: "OLDER-#{patient_id}", identifier_type: 2, location_id: location.id },
      { identifier: old_npid.identifier.downcase, identifier_type: 2, location_id: location.id }
    ]

    task.send(:consolidate_dde_identifiers!, patient_id, current_npid, previous)

    expect(PatientIdentifier.where(patient_id:, identifier_type: 3).pluck(:identifier)).to eq([current_npid.identifier])
    expect(PatientIdentifier.where(patient_id:, identifier_type: 2).order(:identifier).pluck(:identifier))
      .to eq(["OLD-#{patient_id}", "OLDER-#{patient_id}"])
    expect(PatientIdentifier.where(patient_id:, identifier_type: 27).pluck(:identifier)).to eq(["NEW-DOC-#{patient_id}"])
  ensure
    PatientIdentifier.unscoped.where(patient_id:).delete_all if defined?(patient_id)
    Patient.unscoped.where(patient_id:).delete_all if defined?(patient_id)
    Person.unscoped.where(person_id: patient_id).delete_all if defined?(patient_id)
    User.current = previous_user if defined?(previous_user)
  end

  it 'keeps legacy type 2 out of the single-value identifier rule' do
    expect(described_class::MULTIPLE_VALUE_EXCLUDED_IDENTIFIER_TYPES).to include(2, 4, 31)
  end

  it 'detaches only the target when a DDE document ID is shared' do
    task = described_class.new({})
    target_id = 92_000_000 + rand(500_000)
    keeper_id = target_id + 500_000
    user = User.unscoped.first
    location = Location.unscoped.first
    raise 'The test database needs a user and location' unless user && location

    ensure_identifier_type(3, 'National id', user.id)
    ensure_identifier_type(27, 'DDE person document id', user.id)
    [target_id, keeper_id].each do |patient_id|
      Person.create!(person_id: patient_id, gender: 'F', birthdate: Date.new(1990, 1, 1),
                     birthdate_estimated: 0, creator: user.id, uuid: SecureRandom.uuid)
      Patient.create!(patient_id:, creator: user.id)
      create_identifier(patient_id, 3, "SHARED-NPID-#{target_id}", location.id, user.id)
      create_identifier(patient_id, 27, "SHARED-DOC-#{target_id}", location.id, user.id)
    end

    task.send(:detach_shared_dde_identity!, target_id)

    expect(PatientIdentifier.where(patient_id: target_id, identifier_type: [3, 27])).to be_empty
    expect(PatientIdentifier.where(patient_id: keeper_id, identifier_type: [3, 27]).count).to eq(2)
  ensure
    ids = [target_id, keeper_id].compact if defined?(target_id)
    PatientIdentifier.unscoped.where(patient_id: ids).delete_all if ids
    Patient.unscoped.where(patient_id: ids).delete_all if ids
    Person.unscoped.where(person_id: ids).delete_all if ids
  end

  it 'reuses one unlinked exact DDE demographic match after a local rollback' do
    task = described_class.new({})
    name = instance_double(PersonName, given_name: 'Precious', family_name: 'Rabison')
    address = instance_double(PersonAddress, state_province: 'Lilongwe', township_division: 'Njewa',
                                             city_village: 'Ntandire near kankodola school')
    person = instance_double(Person, names: [name], addresses: [address], gender: 'M', birthdate: Date.new(1999, 4, 5))
    patient = instance_double(Patient, id: 559_604, person:)
    remote = {
      'given_name' => 'Precious', 'family_name' => 'Rabison', 'gender' => 'M', 'birthdate' => '1999-04-05',
      'npid' => 'KHYMWE', 'doc_id' => 'a740695a-93a5-11f1-827d-9458fce7901c',
      'attributes' => {
        'current_district' => 'Lilongwe',
        'current_traditional_authority' => 'Njewa',
        'current_village' => 'Ntandire near kankodola school'
      }
    }
    service = instance_double(DdeService, find_remote_demographic_matches: [remote])
    identifier_scope = double('identifier scope', exists?: false)
    allow(PatientIdentifier).to receive(:where)
      .with(identifier_type: 27, identifier: remote['doc_id']).and_return(identifier_scope)

    match = task.send(
      :reusable_remote_dde_person,
      service,
      patient,
      excluding_doc_id: '679e2cc24117bd7316a64b2a44967dcc'
    )

    expect(match).to eq(remote)
  end

  it 'registers a new DDE person for a confirmed shared-document non-keeper' do
    task = described_class.new({})
    patient = instance_double(Patient, id: 335_661)
    service = instance_double(DdeService)
    allow(patient).to receive(:reload).and_return(patient)
    allow(task).to receive(:reusable_remote_dde_person).and_return(nil)
    allow(task).to receive(:detach_shared_dde_identity!)
    allow(service).to receive(:create_patient).with(patient, nil).and_return(patient)

    task.send(:provision_separate_dde_identity!, service, patient, excluding_doc_id: 'missing-doc')

    expect(task).to have_received(:detach_shared_dde_identity!).with(335_661)
    expect(service).to have_received(:create_patient).with(patient, nil)
  end

  it 'replaces a non-keeper unique document that is missing from the local DDE proxy' do
    task = described_class.new({})
    task.instance_variable_set(:@dde_confirmation, described_class::DDE_CONFIRMATION)
    patient = instance_double(Patient, id: 303_999)
    program = instance_double(Program)
    service = instance_double(DdeService)
    current_npid = instance_double(PatientIdentifier, id: 800_001, identifier: 'NEW-NPID')
    current_scope = instance_double(ActiveRecord::Relation)
    ordered_scope = instance_double(ActiveRecord::Relation, first: current_npid)
    previous = [{ identifier: 'SHARED-NPID', identifier_type: 3, location_id: 1 }]

    allow(task).to receive(:current_dde_document_id).with(303_999).and_return('missing-unique-doc')
    allow(task).to receive(:shared_dde_document_owners).with('missing-unique-doc').and_return([patient])
    allow(task).to receive(:active_dde_identifier_snapshots).with(303_999).and_return(previous)
    allow(task).to receive(:dde_program_for).with(patient).and_return(program)
    allow(DdeService).to receive(:new).with(program:).and_return(service)
    allow(service).to receive(:reassign_patient_npid)
      .and_raise(DdeService::MissingRemotePatientError, 'not found')
    allow(task).to receive(:provision_separate_dde_identity!)
    allow(PatientIdentifier).to receive(:where)
      .with(patient_id: 303_999, identifier_type: 3)
      .and_return(current_scope)
    allow(current_scope).to receive(:order)
      .with(date_created: :desc, patient_identifier_id: :desc)
      .and_return(ordered_scope)
    allow(task).to receive(:consolidate_dde_identifiers!)

    task.send(:request_fresh_dde!, patient)

    expect(task).to have_received(:provision_separate_dde_identity!)
      .with(service, patient, excluding_doc_id: 'missing-unique-doc')
    expect(task).to have_received(:consolidate_dde_identifiers!).with(303_999, current_npid, previous)
  end

  it 'keeps the demographic match and redirects a shared-document repair to the nonmatching patient' do
    task = described_class.new({})
    keeper = instance_double(Patient, id: 101)
    nonkeeper = instance_double(Patient, id: 202)
    remote = { 'doc_id' => 'shared-doc', 'npid' => 'ABC123' }
    service = instance_double(DdeService, find_remote_matches_by_doc_id: [remote])
    allow(task).to receive(:exact_remote_demographics?) do |owner, remote_record|
      owner == keeper && remote_record == remote
    end

    target = task.send(
      :shared_document_repair_target!, service, keeper, 'shared-doc', owners: [keeper, nonkeeper]
    )

    expect(target).to eq(nonkeeper)
  end

  it 'defers a shared document when the local proxy cannot identify its keeper' do
    task = described_class.new({})
    first = instance_double(Patient, id: 101)
    second = instance_double(Patient, id: 202)
    service = instance_double(DdeService, find_remote_matches_by_doc_id: [])

    expect do
      task.send(:shared_document_repair_target!, service, first, 'missing-doc', owners: [first, second])
    end.to raise_error(described_class::DeferredDdeRepair, /keeper is unknown pending master sync/)
  end

  it 'defers a DDE patient rejected for incomplete required demographics' do
    task = described_class.new({})
    task.instance_variable_set(:@dde_confirmation, described_class::DDE_CONFIRMATION)
    patient = instance_double(Patient, id: 50_899)
    program = instance_double(Program)
    service = instance_double(DdeService)
    allow(task).to receive(:current_dde_document_id).with(50_899).and_return(nil)
    allow(task).to receive(:shared_dde_document_owners).with(nil).and_return([])
    allow(task).to receive(:active_dde_identifier_snapshots).with(50_899).and_return([])
    allow(task).to receive(:dde_program_for).with(patient).and_return(program)
    allow(DdeService).to receive(:new).with(program:).and_return(service)
    allow(service).to receive(:create_patient)
      .with(patient, nil)
      .and_raise(UnprocessableEntityError, 'Missing home address parameters')

    expect do
      task.send(:request_fresh_dde!, patient)
    end.to raise_error(described_class::DeferredDdeRepair, /patient 50899.*local identifiers were left unchanged/)
  end

  it 'publishes the current and legacy DDE identifiers as searchable CouchDB fields' do
    identifier_row = Struct.new(:identifier, :date_created, :patient_identifier_id)
    identifiers_by_type = {
      2 => [identifier_row.new('OLD-ONE', 2.days.ago, 1), identifier_row.new('OLD-TWO', 1.day.ago, 2)],
      3 => [identifier_row.new('NEW-NPID', Time.current, 3)]
    }
    identifiers = instance_double(ActiveRecord::Associations::CollectionProxy, as_json: [])
    person = instance_double(Person, uuid: SecureRandom.uuid)
    patient = instance_double(Patient, patient_id: 123, patient_identifiers: identifiers, person: person)
    allow(BuildPatientRecordService).to receive(:extract_tei).and_return('')

    record = BuildPatientRecordService.build_basic_info(patient, nil, identifiers_by_type)

    expect(record[:ID]).to eq('NEW-NPID')
    expect(record[:legacyDdeID]).to eq('OLD-TWO')
    expect(record[:legacyDdeIDs]).to eq(%w[OLD-ONE OLD-TWO])
    expect(PatientRecordSearchFields::COUCHDB_INDEXES)
      .to include(name: 'idx_legacyDdeID', ddoc: 'idx_patient_identifiers', fields: ['legacyDdeID'])
  end

  private

  def ensure_identifier_type(id, name, creator)
    PatientIdentifierType.unscoped.find_or_create_by!(patient_identifier_type_id: id) do |type|
      type.name = name
      type.description = name
      type.creator = creator
      type.date_created = Time.current
      type.retired = false
      type.uuid = SecureRandom.uuid
    end
  end

  def create_identifier(patient_id, type, value, location_id, creator)
    PatientIdentifier.create!(patient_id:, identifier_type: type, identifier: value,
                              location_id:, creator:, preferred: 0, uuid: SecureRandom.uuid)
  end
end
