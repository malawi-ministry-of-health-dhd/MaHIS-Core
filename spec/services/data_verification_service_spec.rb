# frozen_string_literal: true

require 'rails_helper'

# The password-changes report used to read a `last_password_reset` user_property
# key that nothing writes any more (password resets now write
# `last_password_updated` instead - see LoginResponseService::PASSWORD_UPDATED_PROPERTY),
# so it always came back empty. It now reads that property, parsing the
# iso8601 timestamp UserService.touch_password_updated! actually writes.
#
# This can only ever report a user's latest change, never a running count:
# user_property keeps one row per (user_id, property), overwritten on every
# change. A real history exists in the `audits` table (User is `audited`),
# but every row it writes for this model has a null auditable_id - User's
# primary key is `user_id`, not `id`, and the audited gem's association
# write path doesn't resolve that. Fixing that is a separate, larger change.
RSpec.describe DataVerificationService do
  let(:actor) { User.first }
  let(:salt) { SecureRandom.hex(8) }

  let(:user) do
    User.create!(
      username: "pwdchg_#{SecureRandom.hex(4)}",
      password: UserService.hash_password('secret', salt), salt:,
      person: create(:person), creator: actor.user_id, location_id: actor.location_id
    )
  end

  before do
    User.current = actor
    create(:person_name, person: user.person, given_name: 'Grace', family_name: 'Phiri', middle_name: nil)
  end

  after do
    UserProperty.where(user_id: user.user_id).delete_all
    user.destroy
  end

  describe '#password_changes' do
    it 'reports a user whose password was updated inside the requested range' do
      UserService.touch_password_updated!(user, at: 2.days.ago)

      report = subject.password_changes(
        start_date: 5.days.ago.to_date.to_s, end_date: Date.today.to_s, program_id: 1
      )

      expect(report['Grace Phiri']&.length).to eq(1)
    end

    it 'excludes a change outside the requested range' do
      UserService.touch_password_updated!(user, at: 10.days.ago)

      report = subject.password_changes(
        start_date: 5.days.ago.to_date.to_s, end_date: Date.today.to_s, program_id: 1
      )

      expect(report['Grace Phiri']).to be_nil
    end
  end
end
