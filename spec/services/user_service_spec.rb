# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserService do
  let(:programs) do
    records = Program.limit(2).to_a
    while records.length < 2
      records << create(:program, name: "Spec Program #{SecureRandom.hex(4)}")
    end
    records
  end

  let(:target_user) do
    User.current || User.first || User.create!(
      username: "spec_user_#{SecureRandom.hex(4)}",
      password: 'test',
      salt: 'salt',
      person: create(:person),
      creator: 1
    )
  end

  describe 'Create User' do
    it 'creates user associated with one more programs' do
      program_ids = programs.map(&:program_id)

      role = Role.first || Role.create!(role: "Spec Role #{SecureRandom.hex(4)}")
      current_location = Location.current || Location.first

      user = UserService.create_user(
        username: "jdoe_#{SecureRandom.hex(4)}",
        password: 'test123',
        given_name: 'John',
        family_name: 'Doe',
        roles: [role.role],
        programs: program_ids,
        location_id: current_location&.location_id,
        villages: [],
        phone: nil
      )

      expect(user.programs.pluck(:program_id)).to match_array(program_ids)
    end
  end

  describe '.update_user' do
    before do
      target_user.user_programs.delete_all
    end

    it 'assigns programs from raw ids' do
      program_ids = programs.map(&:program_id)

      UserService.update_user(target_user, programs: program_ids)

      expect(target_user.user_programs.pluck(:program_id)).to match_array(program_ids)
    end

    it 'assigns programs from frontend-style objects' do
      payload = programs.map { |program| { program_id: program.program_id, name: program.name } }

      UserService.update_user(target_user, programs: payload)

      expect(target_user.user_programs.pluck(:program_id)).to match_array(programs.map(&:program_id))
    end

    it 'clears programs when an empty list is submitted' do
      UserService.update_user(target_user, programs: programs.map(&:program_id))

      UserService.update_user(target_user, programs: [])

      expect(target_user.user_programs.reload).to be_empty
    end

    it 'does not wipe existing programs when an invalid program id is submitted' do
      UserService.update_user(target_user, programs: programs.map(&:program_id))
      original_ids = target_user.user_programs.pluck(:program_id)

      expect do
        UserService.update_user(target_user, programs: [999_999_999])
      end.to raise_error(ActiveRecord::RecordInvalid)

      # The destructive delete must roll back with the failed insert.
      expect(target_user.user_programs.reload.pluck(:program_id)).to match_array(original_ids)
    end

    it 'returns a user whose :programs association reflects the new assignment, not a stale cache' do
      program_ids = programs.map(&:program_id)

      # Mimic the controller, which eager-loads :programs before the update runs.
      target_user.programs.load

      UserService.update_user(target_user, programs: program_ids)

      # Without resetting the association the serialized response would echo the
      # stale (empty) preload instead of what was persisted.
      expect(target_user.programs.map(&:program_id)).to match_array(program_ids)
    end

    it 'assigns programs even when the editor is at a different facility than the target user' do
      # User is location-scoped via Locatable. A superuser editing a user at
      # another facility must still be able to assign programs: passing the
      # loaded user object to UserProgram.create! avoids a location-scoped
      # belongs_to re-query that would otherwise fail with "User must exist".
      other_location = Location.unscoped.where.not(location_id: target_user.location_id).first
      skip 'needs a second location in the test DB' unless other_location

      program_ids = programs.map(&:program_id)
      original_location = Location.current
      Location.current = other_location
      begin
        UserService.update_user(target_user, programs: program_ids)
      ensure
        Location.current = original_location
      end

      expect(target_user.user_programs.reload.pluck(:program_id)).to match_array(program_ids)
    end
  end
end
