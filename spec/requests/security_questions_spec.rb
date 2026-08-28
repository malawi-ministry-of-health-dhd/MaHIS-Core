# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'security question endpoints', type: :request do
  let(:password) { 'correct horse battery' }
  let(:salt) { SecureRandom.hex(8) }

  let(:user) do
    User.create!(
      username: "sq_req_#{SecureRandom.hex(4)}",
      password: UserService.hash_password(password, salt), salt:,
      person: create(:person), creator: User.first.user_id
    )
  end

  let(:token) { UserService.new_authentication_token(user)[:token] }
  let(:headers) { { 'Content-type' => 'application/json', 'Authorization' => token } }
  let(:public_headers) { { 'Content-type' => 'application/json' } }

  let(:answers) do
    [
      { question_id: 'birth_village', answer: 'Nkhulambe' },
      { question_id: 'home_district', answer: 'Blantyre' },
      { question_id: 'mother_maiden_name', answer: 'Banda' }
    ]
  end

  before { LoginThrottleService.unlock!(user.username) }

  after do
    SecurityQuestionService.clear!(user)
    LoginThrottleService.unlock!(user.username)
  end

  def set_questions
    post '/api/v1/security_questions', params: JSON.dump({ answers: }), headers: headers
  end

  describe 'setting up' do
    it 'offers the catalogue and reports nothing configured yet' do
      get '/api/v1/security_questions', headers: headers

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body['questions'].size).to eq(10)
      expect(body['required']).to eq(3)
      expect(body['configured']).to be(false)
    end

    it 'saves the three chosen questions' do
      set_questions

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['selected'].map { |q| q['id'] })
        .to eq(%w[birth_village home_district mother_maiden_name])
    end

    it 'reports them as configured afterwards, without returning answers' do
      set_questions
      get '/api/v1/security_questions', headers: headers

      body = JSON.parse(response.body)
      expect(body['configured']).to be(true)
      expect(response.body).not_to include('Nkhulambe')
      expect(response.body.downcase).not_to include('nkhulambe')
    end

    it 'rejects a bad selection with a message, not a server error' do
      post '/api/v1/security_questions', params: JSON.dump({ answers: answers.take(2) }), headers: headers

      expect(response).to have_http_status(:bad_request)
    end

    it 'requires authentication' do
      post '/api/v1/security_questions', params: JSON.dump({ answers: }), headers: public_headers

      expect(response).to have_http_status(:unauthorized)
    end

    it 'removes them on request' do
      set_questions
      delete '/api/v1/security_questions', headers: headers

      expect(response).to have_http_status(:ok)
      expect(SecurityQuestionService).not_to be_configured(user)
    end
  end

  describe 'the answer hashes are not reachable through the generic property API' do
    it 'refuses to read them' do
      set_questions
      get '/api/v1/user_properties', params: { property: 'security_questions' }, headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses to write them' do
      post '/api/v1/user_properties',
           params: JSON.dump({ property: 'security_questions', property_value: '[]' }),
           headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses the reset token property too' do
      get '/api/v1/user_properties', params: { property: 'security_question_reset' }, headers: headers

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'the reset flow' do
    before { set_questions }

    def fetch_questions(username = user.username)
      get '/api/v1/auth/security_questions', params: { username: }, headers: public_headers
    end

    def verify(submitted, username: user.username)
      post '/api/v1/auth/security_questions/verify',
           params: JSON.dump({ username:, answers: submitted }), headers: public_headers
    end

    it 'hands a locked-out user their three questions without logging in' do
      fetch_questions

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body['questions'].map { |q| q['id'] }).to eq(%w[birth_village home_district mother_maiden_name])
    end

    it 'issues a reset token for correct answers' do
      verify(answers)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['token']).to be_present
    end

    it 'issues a token when two of the three are right' do
      wrong = answers.dup
      wrong[0] = { question_id: 'birth_village', answer: 'Somewhere else' }
      verify(wrong)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['token']).to be_present
    end

    it 'refuses when only one is right' do
      wrong = answers.dup
      wrong[0] = { question_id: 'birth_village', answer: 'Somewhere else' }
      wrong[1] = { question_id: 'home_district', answer: 'Elsewhere' }
      verify(wrong)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'never tells the caller how many answers were right' do
      wrong = answers.dup
      wrong[0] = { question_id: 'birth_village', answer: 'Somewhere else' }
      wrong[1] = { question_id: 'home_district', answer: 'Elsewhere' }
      verify(wrong)

      expect(response.body).not_to match(/\d\s*(of|correct)/i)
      expect(JSON.parse(response.body).keys).to eq(['errors'])
    end

    it 'sets the new password, which then works for login' do
      verify(answers)
      reset_token = JSON.parse(response.body)['token']

      post '/api/v1/auth/security_questions/reset_password',
           params: JSON.dump({ reset_token:, password: 'a-brand-new-password' }), headers: public_headers

      expect(response).to have_http_status(:ok)
      expect(UserService.authenticate_credentials(user.username, 'a-brand-new-password')).to eq(user)
    end

    it 'will not spend the same token twice' do
      verify(answers)
      reset_token = JSON.parse(response.body)['token']

      2.times do
        post '/api/v1/auth/security_questions/reset_password',
             params: JSON.dump({ reset_token:, password: 'another-new-password' }), headers: public_headers
      end

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a password that is too short' do
      verify(answers)
      reset_token = JSON.parse(response.body)['token']

      post '/api/v1/auth/security_questions/reset_password',
           params: JSON.dump({ reset_token:, password: 'abc' }), headers: public_headers

      expect(response).to have_http_status(:bad_request)
    end

    it 'answers an unknown username exactly as it answers one with no questions set' do
      bare = User.create!(username: "sq_bare_#{SecureRandom.hex(4)}", password: 'x', salt: 'salty',
                          person: create(:person), creator: User.first.user_id,
                          location_id: User.first.location_id)

      fetch_questions("definitely-not-a-user-#{SecureRandom.hex(4)}")
      unknown = [response.status, response.body]

      fetch_questions(bare.username)
      no_questions = [response.status, response.body]

      expect(no_questions).to eq(unknown)
    end

    it 'throttles repeated wrong answers' do
      # Two wrong, so the attempt actually fails - one wrong answer is now
      # forgiven and would never reach the throttle.
      wrong = answers.dup
      wrong[0] = { question_id: 'birth_village', answer: 'wrong' }
      wrong[1] = { question_id: 'home_district', answer: 'also wrong' }

      5.times { verify(wrong) }

      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
