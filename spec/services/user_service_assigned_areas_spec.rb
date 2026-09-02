# frozen_string_literal: true

require 'rails_helper'

# A user's assigned villages are served as a hierarchy nested under their
# facility: district -> traditional authority -> village. All four levels live in
# the single `location` table and are told apart only by location_tag_map, and
# the tree is assembled in ONE query -- see UserService.assigned_areas for why it
# cannot go through the Village model.
RSpec.describe UserService, '.assigned_areas' do
  let(:actor) { User.first }
  let(:created_locations) { [] }

  def tag(name)
    LocationTag.find_by(name:) ||
      LocationTag.create!(name:, creator: actor.user_id, date_created: Time.current, uuid: SecureRandom.uuid)
  end

  # Villages/TAs/districts are locations carrying the matching tag (see each
  # model's default scope), so a usable fixture needs the row and the tag map.
  def create_location(tag_name, name, parent: nil, retired: false)
    location = Location.unscoped.create!(
      name:, parent_location: parent, creator: actor.user_id,
      date_created: Time.current, uuid: SecureRandom.uuid, retired:
    )
    ActiveRecord::Base.connection.execute(
      'INSERT INTO location_tag_map (location_id, location_tag_id) ' \
      "VALUES (#{location.location_id}, #{tag(tag_name).location_tag_id})"
    )
    created_locations << location
    location.location_id
  end

  let(:user) do
    User.create!(
      username: "areas_spec_#{SecureRandom.hex(4)}",
      password: UserService.hash_password('x', 'salt'), salt: 'salt',
      person: create(:person), creator: actor.user_id
    )
  end

  before { User.current = actor }

  after do
    UserVillage.where(user_id: user.user_id).delete_all
    # Reverse order: the rows were created parent-first (district, then TA, then
    # villages) and location.parent_location is a self-referencing foreign key.
    created_locations.reverse_each do |location|
      ActiveRecord::Base.connection.execute("DELETE FROM location_tag_map WHERE location_id = #{location.location_id}")
      Location.unscoped.where(location_id: location.location_id).delete_all
    end
  end

  # One district, two TAs under it, two villages under the first TA.
  let(:district) { create_location('District', 'Spec District A', parent: nil) }
  let(:authority_one) { create_location('Traditional Authority', 'Spec TA One', parent: district) }
  let(:authority_two) { create_location('Traditional Authority', 'Spec TA Two', parent: district) }
  let(:village_one) { create_location('Village', 'Spec Village Alpha', parent: authority_one) }
  let(:village_two) { create_location('Village', 'Spec Village Beta', parent: authority_one) }
  let(:village_three) { create_location('Village', 'Spec Village Gamma', parent: authority_two) }

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it 'returns nothing for a user with no assigned villages' do
    expect(described_class.assigned_areas(user)).to eq([])
  end

  it 'nests villages under their traditional authority, under their district' do
    described_class.update_user_villages(user, [village_one, village_two, village_three])

    expect(described_class.assigned_areas(user)).to eq(
      [{
        district_id: district,
        name: 'Spec District A',
        traditional_authorities: [
          { traditional_authority_id: authority_one,
            name: 'Spec TA One',
            villages: [{ village_id: village_one, name: 'Spec Village Alpha' },
                       { village_id: village_two, name: 'Spec Village Beta' }] },
          { traditional_authority_id: authority_two,
            name: 'Spec TA Two',
            villages: [{ village_id: village_three, name: 'Spec Village Gamma' }] }
        ]
      }]
    )
  end

  # The reason districts are an array rather than a single node: nothing
  # constrains a user's villages to one district, so the shape must be able to
  # carry more than one instead of silently misreporting the second.
  it 'returns a separate district node for villages in another district' do
    other_district = create_location('District', 'Spec District B', parent: nil)
    other_authority = create_location('Traditional Authority', 'Spec TA Three', parent: other_district)
    other_village = create_location('Village', 'Spec Village Delta', parent: other_authority)

    described_class.update_user_villages(user, [village_one, other_village])
    areas = described_class.assigned_areas(user)

    expect(areas.map { |area| area[:district_id] }).to contain_exactly(district, other_district)
    expect(areas.map { |area| area[:name] }).to eq(['Spec District A', 'Spec District B'])
  end

  it 'omits villages whose assignment was retired' do
    described_class.update_user_villages(user, [village_one, village_two])
    described_class.update_user_villages(user, [village_one])

    villages = described_class.assigned_areas(user).first[:traditional_authorities].first[:villages]
    expect(villages).to eq([{ village_id: village_one, name: 'Spec Village Alpha' }])
  end

  it 'omits a village that has itself been retired' do
    described_class.update_user_villages(user, [village_one, village_two])
    Location.unscoped.where(location_id: village_two).update_all(retired: 1)

    villages = described_class.assigned_areas(user).first[:traditional_authorities].first[:villages]
    expect(villages).to eq([{ village_id: village_one, name: 'Spec Village Alpha' }])
  end

  # Village#traditional_authority shadows its own belongs_to reader with a
  # find_by, so the ORM route fires a query per village however much is
  # preloaded. This is the regression guard for that: the tree costs one query
  # no matter how many villages a user covers.
  it 'builds the whole tree in a single query' do
    described_class.update_user_villages(user, [village_one, village_two, village_three])

    expect(count_queries { described_class.assigned_areas(user) }).to eq(1)
  end

  describe 'serialization into the user object' do
    before { described_class.update_user_villages(user, [village_one]) }

    it 'is left out by default, so the user list stays cheap' do
      expect(User.with_serialization_preloads.find(user.user_id).as_json['location']).not_to have_key('assigned_areas')
    end

    it 'nests under location when asked for' do
      serializable = User.with_serialization_preloads.find(user.user_id)
      serializable.serialize_assigned_areas = true

      areas = serializable.as_json['location']['assigned_areas']
      expect(areas.first[:district_id]).to eq(district)
    end

    it 'travels with the login payload, which is what the client caches offline' do
      payload = described_class.new_authentication_token(User.unscoped.find(user.user_id))

      expect(payload[:user].as_json['location']['assigned_areas']).to be_present
    end
  end
end
