# frozen_string_literal: true

require 'rails_helper'

# Supervised users - students and interns - are at a facility for a fixed
# rotation. Their accounts now carry an end date and close themselves once it
# passes.
RSpec.describe 'account expiry' do
  let(:actor) { User.first }

  before { User.current = actor }

  # The test database carries no seeded roles, so every role a spec assigns has
  # to exist first. Names must match LoginResponseService::SUPERVISION_REQUIREMENTS
  # exactly - that is what marks a user as supervised.
  before(:all) do
    (LoginResponseService::SUPERVISION_REQUIREMENTS.keys + ['Clinician']).each do |role_name|
      Role.find_or_create_by!(role: role_name) { |role| role.description = role_name }
    end
  end

  def create_user(roles:, duration: nil, username_prefix: 'acct_exp')
    UserService.create_user(
      username: "#{username_prefix}_#{SecureRandom.hex(4)}", password: 'secret123',
      given_name: 'Grace', family_name: 'Phiri', roles:, programs: [],
      location_id: actor.location_id, villages: [], phone: nil,
      account_duration_days: duration
    )
  end

  def stored_expiry(user)
    UserProperty.find_by(user_id: user.user_id, property: UserService::ACCOUNT_EXPIRY_PROPERTY)&.property_value
  end

  def cleanup(user)
    return if user.nil?

    UserProperty.where(user_id: user.user_id).delete_all
    UserRole.where(user_id: user.user_id).delete_all
    User.unscoped.where(user_id: user.user_id).delete_all
  end

  describe 'who gets a period' do
    it 'gives every supervised role the default 90 days' do
      LoginResponseService::SUPERVISION_REQUIREMENTS.each_key do |role_name|
        user = create_user(roles: [role_name])

        expect(user.reload.account_expires_on).to eq(Date.current + UserService::DEFAULT_ACCOUNT_DURATION_DAYS),
                                                  "expected #{role_name} to get a period"
        expect(user.supervised_trainee?).to be(true)
      ensure
        cleanup(user)
      end
    end

    it 'leaves a permanent role with no expiry at all' do
      user = create_user(roles: ['Clinician'])

      expect(user.reload.account_expires_on).to be_nil
      expect(user.supervised_trainee?).to be(false)
      expect(user.account_expired?).to be(false)
    ensure
      cleanup(user)
    end

    it 'honours an explicit duration' do
      user = create_user(roles: ['Intern Clinician'], duration: 30)

      expect(user.reload.account_expires_on).to eq(Date.current + 30)
    ensure
      cleanup(user)
    end

    it 'falls back to the default when the duration is unusable, rather than leaving the account open-ended' do
      [nil, '', '0', '-5', 'abc'].each do |bad_duration|
        user = create_user(roles: ['Intern Clinician'], duration: bad_duration)

        expect(user.reload.account_expires_on).to eq(Date.current + UserService::DEFAULT_ACCOUNT_DURATION_DAYS),
                                                  "expected #{bad_duration.inspect} to fall back to the default"
      ensure
        cleanup(user)
      end
    end
  end

  describe 'where the date is kept' do
    it 'stores an ISO date in user_property, not on the users table' do
      user = create_user(roles: ['Intern Clinician'])

      expect(stored_expiry(user)).to eq((Date.current + UserService::DEFAULT_ACCOUNT_DURATION_DAYS).iso8601)
      expect(User.column_names).not_to include('account_expires_on')
    ensure
      cleanup(user)
    end

    it 'removes the property when the period is cleared, rather than storing a blank' do
      user = create_user(roles: ['Intern Clinician'])
      UserService.clear_account_period!(user)

      expect(stored_expiry(user)).to be_nil
      expect(user.reload.account_expires_on).to be_nil
    ensure
      cleanup(user)
    end

    it 'still serializes account_expires_on to the API, which the admin screens read' do
      user = create_user(roles: ['Intern Clinician'])
      payload = JSON.parse(User.preload_serialization_payload(User.find(user.user_id)).to_json)

      expect(payload['account_expires_on']).to eq((Date.current + UserService::DEFAULT_ACCOUNT_DURATION_DAYS).to_s)
    ensure
      cleanup(user)
    end

    it 'treats an unreadable stored value as no expiry, so a bad property cannot lock anyone out' do
      user = create_user(roles: ['Intern Clinician'])
      UserProperty.where(user_id: user.user_id, property: UserService::ACCOUNT_EXPIRY_PROPERTY)
                  .update_all(property_value: 'not a date')

      expect(user.reload.account_expires_on).to be_nil
      expect(user.account_expired?).to be(false)
    ensure
      cleanup(user)
    end
  end

  describe 'the rule itself' do
    let(:user) { create_user(roles: ['Intern Clinician']) }

    after { cleanup(user) }

    it 'is still valid on the last day of the period' do
      UserService.set_account_expiry!(user, Date.current)

      expect(user.reload.account_expired?).to be(false)
      expect(user.days_until_account_expiry).to eq(0)
    end

    it 'expires the day after' do
      UserService.set_account_expiry!(user, Date.current - 1)

      expect(user.reload.account_expired?).to be(true)
    end

    it 'never expires an account with no end date' do
      UserService.clear_account_period!(user)

      expect(user.reload.account_expired?).to be(false)
      expect(user.days_until_account_expiry).to be_nil
    end
  end

  describe 'editing a trainee' do
    let(:user) { create_user(roles: ['Intern Clinician']) }

    after { cleanup(user) }

    it 'does not restart the clock when something unrelated is saved' do
      UserService.set_account_expiry!(user, Date.current + 5)

      UserService.update_user(user, ActionController::Parameters.new(phone: '0999000111',
                                                                    roles: ['Intern Clinician']).permit!)

      expect(user.reload.account_expires_on).to eq(Date.current + 5)
    end

    it 'extends the period when a duration is supplied' do
      UserService.set_account_expiry!(user, Date.current - 1)

      UserService.update_user(user, ActionController::Parameters.new(account_duration_days: 60,
                                                                    roles: ['Intern Clinician']).permit!)

      expect(user.reload.account_expires_on).to eq(Date.current + 60)
    end

    it 'clears the expiry when the trainee moves to a permanent role' do
      UserService.update_user(user, ActionController::Parameters.new(roles: ['Clinician']).permit!)

      expect(user.reload.account_expires_on).to be_nil
    end

    it 'starts a period when a permanent user becomes a trainee' do
      permanent = create_user(roles: ['Clinician'])
      expect(permanent.reload.account_expires_on).to be_nil

      UserService.update_user(permanent, ActionController::Parameters.new(roles: ['Student Nurse']).permit!)

      expect(permanent.reload.account_expires_on).to eq(Date.current + UserService::DEFAULT_ACCOUNT_DURATION_DAYS)
    ensure
      cleanup(permanent)
    end
  end

  describe 'logging in' do
    let(:password) { 'secret123' }
    let(:user) { create_user(roles: ['Intern Clinician']) }

    after { cleanup(user) }

    it 'lets a trainee inside their period log in' do
      expect(UserService.authenticate_credentials(user.username, password)&.user_id).to eq(user.user_id)
    end

    it 'refuses an expired account with a distinct error carrying the end date' do
      UserService.set_account_expiry!(user, Date.current - 1)

      expect { UserService.authenticate_credentials(user.username, password) }
        .to raise_error(AccountExpiredError) { |error| expect(error.expired_on).to eq(Date.current - 1) }
    end

    it 'deactivates the account and revokes its token at that login' do
      UserService.new_authentication_token(user)
      expect(user.reload.authentication_token).to be_present

      UserService.set_account_expiry!(user, Date.current - 1)
      suppress(AccountExpiredError) { UserService.authenticate_credentials(user.username, password) }

      user = User.unscoped.find(self.user.user_id)
      expect(user.deactivated_on).to be_present
      expect(user.authentication_token).to be_nil
    end

    it 'still explains why on later attempts, once the account is already deactivated' do
      UserService.set_account_expiry!(user, Date.current - 1)
      suppress(AccountExpiredError) { UserService.authenticate_credentials(user.username, password) }

      expect { UserService.authenticate_credentials(user.username, password) }
        .to raise_error(AccountExpiredError)
    end

    # The whole point of checking the password first: an unauthenticated caller
    # must not be able to tell an expired account from a non-existent one.
    it 'says nothing about an expired account to someone with the wrong password' do
      UserService.set_account_expiry!(user, Date.current - 1)

      expect(UserService.authenticate_credentials(user.username, 'WrongPassword!')).to be_nil
    end
  end

  describe 'the nightly sweep' do
    it 'closes accounts past their date and leaves the rest alone' do
      expired = create_user(roles: ['Intern Nurse'])
      UserService.set_account_expiry!(expired, Date.current - 5)
      in_date = create_user(roles: ['Intern Nurse'])
      permanent = create_user(roles: ['Clinician'])

      DeactivateExpiredAccountsJob.new.perform

      expect(User.unscoped.find(expired.user_id).deactivated_on).to be_present
      expect(User.unscoped.find(in_date.user_id).deactivated_on).to be_nil
      expect(User.unscoped.find(permanent.user_id).deactivated_on).to be_nil
    ensure
      [expired, in_date, permanent].each { |user| cleanup(user) }
    end

    it 'does not touch an account that expires today, which is still valid' do
      user = create_user(roles: ['Intern Nurse'])
      UserService.set_account_expiry!(user, Date.current)

      DeactivateExpiredAccountsJob.new.perform

      expect(User.unscoped.find(user.user_id).deactivated_on).to be_nil
    ensure
      cleanup(user)
    end
  end
end
