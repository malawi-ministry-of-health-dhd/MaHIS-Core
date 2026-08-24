# frozen_string_literal: true

require 'rails_helper'

# Covers the routing and parameter plumbing for the restore screen; the void and
# restore behaviour itself is covered in spec/services/patient_unvoid_spec.rb.
RSpec.describe 'Voided patients API', type: :request do
  let(:service) { PatientService.new }

  before do
    allow_any_instance_of(Api::V1::PatientsController).to receive(:authenticate).and_return(true)
    allow(BuildPatientRecordService).to receive(:build_patient_record).and_return({ 'ID' => 'rebuilt' })
    allow(CouchdbPatientService).to receive(:sync_patient_to_couchdb).and_return({ success: true })
    allow(DdeService).to receive(:dde_enabled?).and_return(false)
  end

  after do
    return unless defined?(@patient_id) && @patient_id

    Observation.unscoped.where(person_id: @patient_id).delete_all
    Encounter.unscoped.where(patient_id: @patient_id).delete_all
    PatientVoidBatch.where(patient_id: @patient_id).delete_all
    Patient.unscoped.where(patient_id: @patient_id).delete_all
    PersonName.unscoped.where(person_id: @patient_id).delete_all
    Person.unscoped.where(person_id: @patient_id).delete_all
  end

  def void_a_patient
    patient = create(:patient)
    @patient_id = patient.patient_id
    person = Person.unscoped.find(@patient_id)
    create(:person_name, person:)
    create(:observation, person:, encounter: create(:encounter, patient:))
    service.void_patient(patient, 'Voided the wrong client', daemonize: false)
    patient
  end

  it 'lists voided patients' do
    void_a_patient

    get '/api/v1/patients/voided', params: { from: Date.today.to_s }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['total']).to be >= 1
    expect(body['limit']).to eq(PatientService::PAGE_LIMIT)
    row = body['patients'].find { |entry| entry['patient_id'] == @patient_id }
    expect(row['void_reason']).to eq('Voided the wrong client')
    expect(row['void_batch_id']).to be_present
  end

  it 'honours limit and offset' do
    void_a_patient

    get '/api/v1/patients/voided', params: { from: Date.today.to_s, limit: 1, offset: 0 }
    first_page = JSON.parse(response.body)

    expect(response).to have_http_status(:ok)
    expect(first_page['patients'].size).to eq(1)
    expect(first_page['offset']).to eq(0)
    expect(first_page['limit']).to eq(1)
  end

  it 'previews a restore' do
    void_a_patient

    get "/api/v1/patients/#{@patient_id}/void_restore_preview"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['exact']).to be(true)
    expect(body['restorable']['obs']).to eq(1)
  end

  it 'restores a patient' do
    void_a_patient

    post "/api/v1/patients/#{@patient_id}/unvoid", params: { reason: 'Voided in error' }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['row_counts']['patient']).to eq(1)
    expect(body['couchdb_restored']).to be(true)
    expect(Patient.find_by(patient_id: @patient_id)).to be_present
  end

  it 'rejects a restore with no reason' do
    void_a_patient

    post "/api/v1/patients/#{@patient_id}/unvoid"

    expect(response).to have_http_status(:bad_request)
    expect(Patient.find_by(patient_id: @patient_id)).to be_nil
  end
end
