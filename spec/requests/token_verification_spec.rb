# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/auth/verify_token', type: :request do
  it 'returns a valid flag for an active token' do
    token = UserService.new_authentication_token(User.current)[:token]

    post '/api/v1/auth/verify_token', headers: { 'Authorization' => token }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq('valid' => true)
  end

  it 'rejects a missing token' do
    post '/api/v1/auth/verify_token'

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects an invalid token' do
    post '/api/v1/auth/verify_token', headers: { 'Authorization' => 'invalid-token' }

    expect(response).to have_http_status(:unauthorized)
  end
end
