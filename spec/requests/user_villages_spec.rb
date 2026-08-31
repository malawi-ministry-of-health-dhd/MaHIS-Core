# frozen_string_literal: true

require 'rails_helper'

# End-to-end cover for the village assignment endpoints: the params the client
# actually sends, through the controller's authorisation and permit, into the
# service, and back out as JSON.
RSpec.describe 'user villages endpoints', type: :request do
  let(:actor) { User.first }
  let(:token) { UserService.new_authentication_token(actor)[:token] }
  let(:headers) { { 'Content-type' => 'application/json', 'Authorization' => token } }

  let(:village_tag) do
    LocationTag.find_by(name: 'Village') ||
      LocationTag.create!(name: 'Village', creator: actor.user_id, date_created: Time.current, uuid: SecureRandom.uuid)
  end

  let(:created_locations) { [] }

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

  let(:village_a) { create_village }
  let(:village_b) { create_village }

  let(:target) do
    User.create!(
      username: "village_req_#{SecureRandom.hex(4)}",
      password: UserService.hash_password('x', 'salt'), salt: 'salt',
      person: create(:person), creator: actor.user_id, location_id: actor.location_id
    )
  end

  after do
    UserVillage.where(user_id: target.user_id).delete_all
    created_locations.each do |location|
      ActiveRecord::Base.connection.execute("DELETE FROM location_tag_map WHERE location_id = #{location.location_id}")
      Location.unscoped.where(location_id: location.location_id).delete_all
    end
  end

  def assign(ids)
    put "/api/v1/users/#{target.user_id}/update_user_villages",
        params: JSON.dump({ user_village_ids: ids }),
        headers: headers
  end

  def read_back
    get "/api/v1/users/#{target.user_id}/get_user_villages", headers: headers
    JSON.parse(response.body)['villages'].map { |row| row['village_id'].to_i }.sort
  end

  it 'saves the assigned villages' do
    assign([village_a, village_b])

    expect(response).to have_http_status(:ok)
    expect(UserVillage.where(user_id: target.user_id, retired: 0).pluck(:village_id).map(&:to_i).sort)
      .to eq([village_a, village_b].sort)
  end

  it 'returns the saved set in the response body' do
    assign([village_a])

    expect(JSON.parse(response.body)['villages'].map { |row| row['village_id'].to_i }).to eq([village_a])
  end

  it 'reads back exactly what was saved' do
    assign([village_a, village_b])

    expect(read_back).to eq([village_a, village_b].sort)
  end

  it 'accepts ids sent as strings, which is what JSON from the client carries' do
    assign([village_a.to_s, village_b.to_s])

    expect(response).to have_http_status(:ok)
    expect(read_back).to eq([village_a, village_b].sort)
  end

  it 'retires the villages left out of a later save' do
    assign([village_a, village_b])
    assign([village_a])

    expect(read_back).to eq([village_a])
  end

  it 're-assigns a village that was previously removed' do
    assign([village_a, village_b])
    assign([village_a])
    assign([village_a, village_b])

    expect(read_back).to eq([village_a, village_b].sort)
  end

  it 'clears every village when the client sends an empty list' do
    assign([village_a])
    assign([])

    expect(response).to have_http_status(:ok)
    expect(read_back).to eq([])
  end
end
