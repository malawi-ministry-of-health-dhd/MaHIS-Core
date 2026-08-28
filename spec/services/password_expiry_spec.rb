# frozen_string_literal: true

require 'rails_helper'

# The 90-day password expiry, and the gaps that made it not work.
RSpec.describe 'password expiry' do
  let(:actor) { User.first }
  let(:salt) { SecureRandom.hex(8) }

  let(:user) do
    User.create!(
      username: "expiry_#{SecureRandom.hex(4)}",
      password: UserService.hash_password('secret', salt), salt:,
      person: create(:person), creator: actor.user_id, location_id: actor.location_id
    )
  end

  before { User.current = actor }

  after { UserProperty.where(user_id: user.user_id).delete_all }

  def stored_value
    UserProperty.find_by(user_id: user.user_id, property: LoginResponseService::PASSWORD_UPDATED_PROPERTY)&.property_value
  end

  describe 'the rule itself' do
    it 'expires a password older than the validity period' do
      expect(LoginResponseService.password_expired?((LoginResponseService::PASSWORD_VALIDITY_PERIOD + 1.day).ago.iso8601))
        .to be(true)
    end

    it 'leaves a password inside the window alone' do
      expect(LoginResponseService.password_expired?(1.day.ago.iso8601)).to be(false)
    end

    it 'reads a value written as a plain timestamp as well as an iso8601 one' do
      expect(LoginResponseService.password_expired?(100.days.ago.to_s)).to be(true)
      expect(LoginResponseService.password_expired?(100.days.ago.to_date.to_s)).to be(true)
    end

    it 'treats an unreadable value as not expired, so a bad string cannot lock anyone out' do
      expect(LoginResponseService.password_expired?('not a date')).to be(false)
      expect(LoginResponseService.password_expired?(nil)).to be(false)
    end

    it 'is stated once - the controller delegates to it' do
      UserService.expire_password!(user)

      expect(LoginResponseService.password_needs_update?(user.user_id)).to be(true)
    end
  end

  describe 'a newly created user' do
    it 'starts the expiry clock, so the policy applies to them at all' do
      created = UserService.create_user(
        username: "expiry_new_#{SecureRandom.hex(4)}", password: 'secret123',
        given_name: 'Grace', family_name: 'Phiri', roles: [], programs: [],
        location_id: actor.location_id, villages: [], phone: nil
      )

      property = UserProperty.find_by(user_id: created.user_id,
                                      property: LoginResponseService::PASSWORD_UPDATED_PROPERTY)

      expect(property&.property_value).to be_present
      expect(LoginResponseService.password_needs_update?(created.user_id)).to be(false)
    ensure
      UserProperty.where(user_id: created&.user_id).delete_all
      created&.destroy
    end
  end

  # The behaviour the whole policy hangs off: a brand-new user is made to set
  # their own password before they can use the system. It is driven by
  # last_login_time being absent, NOT by the password date - so starting the
  # expiry clock at creation must not quietly switch it off.
  describe 'a brand-new user on their very first login' do
    let!(:fresh) do
      UserService.create_user(
        username: "expiry_first_#{SecureRandom.hex(4)}", password: 'secret123',
        given_name: 'Grace', family_name: 'Phiri', roles: [], programs: [],
        location_id: actor.location_id, villages: [], phone: nil
      )
    end

    after do
      UserProperty.where(user_id: fresh.user_id).delete_all
      fresh.destroy
    end

    it 'is still asked to change the password, even though the password date is now set' do
      response = LoginResponseService.build(fresh, nil, mark_login: false)

      expect(response[:first_time_login]).to be(true)
      expect(response[:password_needs_update]).to be(false)
    end

    it 'counts as a forced change for the login endpoint' do
      response = LoginResponseService.build(fresh, nil, mark_login: false)

      expect(response[:first_time_login] || response[:password_needs_update]).to be(true)
    end

    it 'stops being a first-time login once the login is marked' do
      LoginResponseService.build(fresh, 'a-token')

      expect(LoginResponseService.first_time_login?(fresh)).to be(false)
    end

    it 'is not held back by supervision while the password change is pending' do
      response = LoginResponseService.build(fresh, 'a-token', mark_login: false)

      expect(response[:supervision_required]).to be_nil
    end
  end

  describe 'expiring and refreshing' do
    it 'expire_password! puts the user past the window' do
      UserService.expire_password!(user)

      expect(LoginResponseService.password_needs_update?(user.user_id)).to be(true)
    end

    it 'touch_password_updated! brings them back inside it' do
      UserService.expire_password!(user)
      UserService.touch_password_updated!(user)

      expect(LoginResponseService.password_needs_update?(user.user_id)).to be(false)
    end

    it 'a reset clears the expiry, so the user is not asked again immediately' do
      UserService.expire_password!(user)

      UserService.reset_password_for(user, 'a-fresh-password')

      expect(LoginResponseService.password_needs_update?(user.user_id)).to be(false)
      expect(UserService.authenticate_credentials(user.username, 'a-fresh-password')).to eq(user)
    end

    it 'writes a value the rule can read back' do
      UserService.touch_password_updated!(user)

      expect(LoginResponseService.password_expired?(stored_value)).to be(false)
    end
  end
end
