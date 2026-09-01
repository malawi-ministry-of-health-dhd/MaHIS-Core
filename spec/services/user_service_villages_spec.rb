# frozen_string_literal: true

require 'rails_helper'

# Assigning villages to a user is a replace-the-whole-set operation that never
# deletes rows: removals are retired and re-additions revive the retired row.
# The regression these specs pin down is that a village which had ever been
# removed could not be assigned again - the old code compared the requested ids
# against ALL rows, retired ones included, so the revive never happened.
RSpec.describe UserService, 'village assignment' do
  let(:actor) { User.first }

  let(:village_tag) do
    LocationTag.find_by(name: 'Village') ||
      LocationTag.create!(name: 'Village', creator: actor.user_id, date_created: Time.current, uuid: SecureRandom.uuid)
  end

  # Villages are locations carrying the 'Village' tag (see the Village model's
  # default scope), so a usable fixture needs both the row and the tag map.
  def create_village
    location = Location.unscoped.create!(
      name: "Spec Village #{SecureRandom.hex(4)}",
      creator: actor.user_id, date_created: Time.current, uuid: SecureRandom.uuid, retired: false
    )
    ActiveRecord::Base.connection.execute(
      "INSERT INTO location_tag_map (location_id, location_tag_id) " \
      "VALUES (#{location.location_id}, #{village_tag.location_tag_id})"
    )
    created_locations << location
    location.location_id
  end

  let(:created_locations) { [] }
  let(:village_a) { create_village }
  let(:village_b) { create_village }

  let(:user) do
    User.create!(
      username: "village_spec_#{SecureRandom.hex(4)}",
      password: UserService.hash_password('x', 'salt'), salt: 'salt',
      person: create(:person), creator: actor.user_id
    )
  end

  before { User.current = actor }

  after do
    UserVillage.where(user_id: user.user_id).delete_all
    created_locations.each do |location|
      ActiveRecord::Base.connection.execute("DELETE FROM location_tag_map WHERE location_id = #{location.location_id}")
      Location.unscoped.where(location_id: location.location_id).delete_all
    end
  end

  def active_village_ids
    UserService.get_user_villages(user).where(retired: 0).map { |row| row.village_id.to_i }.sort
  end

  def all_rows
    UserVillage.where(user_id: user.user_id).order(:user_village_id)
  end

  describe 'assigning' do
    it 'assigns the requested villages' do
      UserService.update_user_villages(user, [village_a, village_b])

      expect(active_village_ids).to eq([village_a, village_b].sort)
    end

    it 'returns the resulting active assignments, which is what the endpoint renders' do
      result = UserService.update_user_villages(user, [village_a])

      expect(result.map { |row| row.village_id.to_i }).to eq([village_a])
    end

    it 'ignores duplicate ids in one request rather than writing two rows' do
      UserService.update_user_villages(user, [village_a, village_a, village_a])

      expect(all_rows.count).to eq(1)
    end
  end

  describe 'removing' do
    it 'retires the row instead of deleting it, keeping the history' do
      UserService.update_user_villages(user, [village_a, village_b])
      UserService.update_user_villages(user, [village_a])

      expect(active_village_ids).to eq([village_a])
      expect(all_rows.count).to eq(2)
    end

    it 'records who retired it and when' do
      UserService.update_user_villages(user, [village_a, village_b])
      UserService.update_user_villages(user, [village_a])

      retired = UserVillage.find_by(user_id: user.user_id, village_id: village_b)
      expect(retired.retired.to_i).to eq(1)
      expect(retired.date_retired).to be_present
      expect(retired.retired_by).to eq(actor.user_id)
    end

    it 'clears every village when given an empty list' do
      UserService.update_user_villages(user, [village_a, village_b])
      UserService.update_user_villages(user, [])

      expect(active_village_ids).to be_empty
    end
  end

  describe 're-assigning a village that was removed (the regression)' do
    it 'brings it back' do
      UserService.update_user_villages(user, [village_a, village_b])
      UserService.update_user_villages(user, [village_a])

      UserService.update_user_villages(user, [village_a, village_b])

      expect(active_village_ids).to eq([village_a, village_b].sort)
    end

    it 'revives the existing row rather than inserting a second one' do
      UserService.update_user_villages(user, [village_a])
      UserService.update_user_villages(user, [])
      UserService.update_user_villages(user, [village_a])

      expect(all_rows.count).to eq(1)
      expect(all_rows.first.retired.to_i).to eq(0)
      expect(all_rows.first.date_retired).to be_nil
      expect(all_rows.first.retired_by).to be_nil
    end

    it 'survives being removed and restored repeatedly' do
      3.times do
        UserService.update_user_villages(user, [village_a, village_b])
        UserService.update_user_villages(user, [village_a])
      end
      UserService.update_user_villages(user, [village_a, village_b])

      expect(active_village_ids).to eq([village_a, village_b].sort)
      expect(all_rows.count).to eq(2)
    end
  end

  describe 'an id that is not a village' do
    it 'is reported rather than silently dropped' do
      expect { UserService.update_user_villages(user, [village_a, 999_999_999]) }
        .to raise_error(ActiveRecord::RecordInvalid, /Village must exist/)
    end

    it 'leaves nothing half-applied' do
      UserService.update_user_villages(user, [village_a])

      expect { UserService.update_user_villages(user, [village_a, village_b, 999_999_999]) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(active_village_ids).to eq([village_a])
    end
  end

  describe 'reading back' do
    it 'excludes retired assignments from what the endpoint returns' do
      UserService.update_user_villages(user, [village_a, village_b])
      UserService.update_user_villages(user, [village_b])

      villages = UserService.get_user_villages(user).where(retired: 0)

      expect(villages.map { |row| row.village_id.to_i }).to eq([village_b])
    end

    it 'still exposes the retired rows when not filtered, for history' do
      UserService.update_user_villages(user, [village_a])
      UserService.update_user_villages(user, [])

      expect(UserService.get_user_villages(user).count).to eq(1)
    end
  end
end
