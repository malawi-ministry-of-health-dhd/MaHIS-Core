# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::BedsController, type: :controller do
  describe 'GET #index' do
    let(:creator_id) { User.current&.user_id || User.first&.user_id || 1 }
    let(:now) { Time.current }
    let(:parent_location) { create_location('Parent Ward') }
    let(:child_location) { create_location('Child Room A', parent_location.location_id) }
    let(:second_child_location) { create_location('Child Room B', parent_location.location_id) }
    let(:other_parent_location) { create_location('Other Ward') }
    let(:outside_child_location) { create_location('Outside Room', other_parent_location.location_id) }
    let(:child_bed) { create_bed('A1', child_location.location_id) }
    let(:second_child_bed) { create_bed('B1', second_child_location.location_id) }
    let(:outside_bed) { create_bed('C1', outside_child_location.location_id) }

    before do
      allow(controller).to receive(:authenticate).and_return(true)

      child_bed
      second_child_bed
      outside_bed
    end

    after do
      Bed.where(bed_id: [child_bed.bed_id, second_child_bed.bed_id, outside_bed.bed_id]).delete_all
      Location.where(
        location_id: [
          child_location.location_id,
          second_child_location.location_id,
          outside_child_location.location_id
        ]
      ).delete_all
      Location.where(
        location_id: [
          parent_location.location_id,
          other_parent_location.location_id
        ]
      ).delete_all
    end

    it 'returns beds assigned to child locations of the parent location' do
      get :index, params: { parent_section_id: parent_location.location_id, paginate: 'false' }

      bed_ids = JSON.parse(response.body).pluck('bed_id')

      expect(response).to have_http_status(:ok)
      expect(bed_ids).to contain_exactly(child_bed.bed_id, second_child_bed.bed_id)
    end

    def create_location(name, parent_location_id = nil)
      Location.create!(
        name: name,
        parent_location: parent_location_id,
        creator: creator_id,
        date_created: now,
        retired: false,
        uuid: SecureRandom.uuid
      )
    end

    def create_bed(bed_number, section_id)
      Bed.create!(
        uuid: SecureRandom.uuid,
        bed_number: bed_number,
        section_id: section_id,
        bed_status: Bed::ACTIVE_STATUS,
        creator: creator_id,
        date_created: now,
        retired: false
      )
    end
  end
end
