# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::ProgramAppointmentsController, type: :controller do
  before do
    allow(controller).to receive(:authenticate).and_return(true)
  end

  describe 'GET #booked_appointments' do
    it 'converts date params to dates and passes them to the service' do
      expect(ProgramAppointmentService).to receive(:booked_appointments).with(
        '42',
        Date.new(2024, 2, 10),
        Date.new(2024, 2, 15),
        'jane',
        location_id: User.current.location_id
      ).and_return([])

      get :booked_appointments, params: {
        program_id: '42',
        date: '2024-02-10',
        end_date: '2024-02-15',
        srch_text: 'jane'
      }

      expect(response).to have_http_status(:ok)
    end

    it 'defaults the end date to the selected date when no end date is provided' do
      expect(ProgramAppointmentService).to receive(:booked_appointments).with(
        '42',
        Date.new(2024, 2, 10),
        Date.new(2024, 2, 10),
        '',
        location_id: User.current.location_id
      ).and_return([])

      get :booked_appointments, params: {
        program_id: '42',
        date: '2024-02-10'
      }

      expect(response).to have_http_status(:ok)
    end

    it 'handles a future appointment date and returns the results for that date' do
      future_date = Date.new(2030, 6, 20)

      expect(ProgramAppointmentService).to receive(:booked_appointments).with(
        '42',
        future_date,
        future_date,
        '',
        location_id: User.current.location_id
      ).and_return([{ 'date' => future_date.iso8601 }])

      get :booked_appointments, params: {
        program_id: '42',
        date: '2030-06-20'
      }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq([{ 'date' => future_date.iso8601 }])
    end
  end

  describe 'GET #scheduled_appointments' do
    it 'converts the requested date and defaults the end date to the same day' do
      expect(ProgramAppointmentService).to receive(:booked_appointments).with(
        42,
        Date.new(2024, 2, 10),
        Date.new(2024, 2, 10),
        '',
        location_id: User.current.location_id
      ).and_return([])

      get :scheduled_appointments, params: {
        program_id: 42,
        date: '2024-02-10'
      }

      expect(response).to have_http_status(:ok)
    end
  end
end
