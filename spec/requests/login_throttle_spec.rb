# frozen_string_literal: true

require 'rails_helper'

# The HTTP contract the client depends on: a throttled login must come back as
# 429 with Retry-After, and must not be distinguishable from a lock.
RSpec.describe 'POST /api/v1/auth/login throttling', type: :request do
  let(:password) { 'correct horse battery staple' }
  let(:salt) { SecureRandom.hex(8) }

  let!(:user) do
    User.create!(
      username: "throttle_req_#{SecureRandom.hex(4)}",
      password: UserService.hash_password(password, salt),
      salt:,
      person: create(:person),
      creator: 1
    )
  end

  let(:headers) { { 'Content-type' => 'application/json' } }

  before { LoginThrottleService.unlock!(user.username) }

  def login(pass, username: user.username)
    post '/api/v1/auth/login',
         params: JSON.dump({ username:, password: pass }),
         headers: headers
  end

  it 'answers a wrong password with 401 while attempts remain' do
    login('wrong')

    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)['errors']).to eq(['Invalid user or password'])
  end

  it 'answers 429 with a Retry-After header once the back-off kicks in' do
    4.times { login('wrong') }

    login('wrong')

    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers['Retry-After']).to eq('5')

    body = JSON.parse(response.body)
    expect(body['retry_after']).to eq(5)
    expect(body['errors']).to eq([LoginThrottleService::MESSAGE])
  end

  it 'throttles the correct password too, so a lock cannot be walked past' do
    4.times { login('wrong') }

    login(password)

    expect(response).to have_http_status(:too_many_requests)
  end

  it 'says nothing about whether the account exists' do
    # A fresh unknown name per run: a fixed one would carry Redis state between
    # examples and runs and make this order-dependent.
    unknown = "no-such-user-#{SecureRandom.hex(4)}"

    5.times { login('wrong', username: unknown) }
    unknown_status = response.status
    unknown_body = JSON.parse(response.body)

    5.times { login('wrong') }
    real_body = JSON.parse(response.body)

    expect(response.status).to eq(unknown_status)
    expect(real_body['errors']).to eq(unknown_body['errors'])
    expect(real_body.keys).to match_array(unknown_body.keys)
    # Seconds can differ by a tick of TTL decay, not by whether the user exists.
    expect(real_body['retry_after']).to be_within(2).of(unknown_body['retry_after'])
  end

  describe 'the per-address layer, end to end' do
    let(:public_address) { '41.87.10.20' }

    before do
      stub_const('LoginThrottleService::IP_FAILURE_THRESHOLD', 3)
      LoginThrottleService.unlock_address!(public_address)
    end

    after { LoginThrottleService.unlock_address!(public_address) }

    def login_from(address, username:, password: 'wrong')
      post '/api/v1/auth/login',
           params: JSON.dump({ username:, password: }),
           headers: headers,
           env: { 'REMOTE_ADDR' => address }
    end

    it 'picks the client address up from the request and blocks a flood' do
      3.times { |i| login_from(public_address, username: "sweep_#{i}") }

      # A completely different, untouched username from the same address.
      login_from(public_address, username: "still_clean_#{SecureRandom.hex(4)}")

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers['Retry-After']).to eq(LoginThrottleService::IP_BLOCK_DURATION.to_i.to_s)
    end

    it 'leaves loopback alone, so an unconfigured proxy cannot block every user at once' do
      10.times { |i| login_from('127.0.0.1', username: "loopback_#{i}") }

      login_from('127.0.0.1', username: "still_clean_#{SecureRandom.hex(4)}")

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'still logs a valid user in' do
    login(password)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('authorization', 'token')).to be_present
  end
end
