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
  end
end
