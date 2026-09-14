# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserService, 'clinic assignment' do
  let(:actor) { User.first }
  let(:facility) do
    Location.unscoped.create!(
      name: "Spec Facility #{SecureRandom.hex(4)}",
      creator: actor.user_id,
      date_created: Time.current,
      uuid: SecureRandom.uuid,
      retired: false
    )
  end

  let(:clinic_a) do
    Location.unscoped.create!(
      name: "Spec Clinic A #{SecureRandom.hex(4)}",
      parent_location: facility.location_id,
      creator: actor.user_id,
      date_created: Time.current,
      uuid: SecureRandom.uuid,
      retired: false
    )
  end

  let(:clinic_b) do
    Location.unscoped.create!(
      name: "Spec Clinic B #{SecureRandom.hex(4)}",
      parent_location: facility.location_id,
      creator: actor.user_id,
      date_created: Time.current,
      uuid: SecureRandom.uuid,
      retired: false
    )
  end

  let(:user) do
    User.create!(
      username: "clinic_spec_#{SecureRandom.hex(4)}",
      password: UserService.hash_password('x', 'salt'),
      salt: 'salt',
      person: create(:person),
      creator: actor.user_id,
      location_id: facility.location_id
    )
  end

  before do
    User.current = actor
    # User has a Locatable default_scope that filters by Location.current (falling
    # back to the acting user's own location), so without this the freshly-created
    # `user` -- whose location_id points at the spec's own `facility` -- would be
    # invisible to any subsequent `User` lookup, including belongs_to presence checks.
    Location.current = facility
  end

  after do
    Location.current = nil
    UserClinicAssignment.where(user_id: user.user_id).delete_all
    [clinic_a, clinic_b, facility].compact.each do |location|
      Location.unscoped.where(location_id: location.location_id).delete_all
    end
  end

  def active_assignment
    UserService.current_clinic_assignment(user)
  end

  def all_rows
    UserClinicAssignment.where(user_id: user.user_id).order(:user_clinic_assignment_id)
  end

  describe 'assigning' do
    it 'creates an active clinic assignment for the user' do
      assignment = UserService.update_clinic_assignment(user, clinic_a.location_id)

      expect(assignment.location_id).to eq(clinic_a.location_id.to_s)
      expect(active_assignment.location_id).to eq(clinic_a.location_id.to_s)
      expect(all_rows.count).to eq(1)
      expect(all_rows.first.retired.to_i).to eq(0)
    end

    it 'does nothing when the same clinic is assigned again' do
      UserService.update_clinic_assignment(user, clinic_a.location_id)

      expect { UserService.update_clinic_assignment(user, clinic_a.location_id) }
        .not_to change { UserClinicAssignment.where(user_id: user.user_id).count }
    end
  end

  describe 'replacing' do
    it 'retires the old clinic assignment and creates a new active row' do
      UserService.update_clinic_assignment(user, clinic_a.location_id)
      UserService.update_clinic_assignment(user, clinic_b.location_id)

      expect(active_assignment.location_id).to eq(clinic_b.location_id.to_s)
      expect(all_rows.count).to eq(2)
      expect(all_rows.where(location_id: clinic_a.location_id.to_s).first.retired.to_i).to eq(1)
      expect(all_rows.where(location_id: clinic_a.location_id.to_s).first.date_retired).to be_present
      expect(all_rows.where(location_id: clinic_b.location_id.to_s).first.retired.to_i).to eq(0)
    end

    it 'records who retired the old assignment and when' do
      UserService.update_clinic_assignment(user, clinic_a.location_id)
      UserService.update_clinic_assignment(user, clinic_b.location_id)

      retired_row = all_rows.where(location_id: clinic_a.location_id.to_s).first
      expect(retired_row.retired_by).to eq(actor.user_id)
      expect(retired_row.date_retired).to be_present
    end
  end
end
