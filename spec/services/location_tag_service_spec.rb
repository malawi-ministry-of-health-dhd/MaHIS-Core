# frozen_string_literal: true

require 'rails_helper'

# Location tags double as record identity: Village, District,
# TraditionalAuthority and Region each default_scope on their own tag. So the
# service that lets an administrator tag an existing location has to be able to
# add 'Village Clinic' to a village without ever putting the village's own
# 'Village' tag within reach.
RSpec.describe LocationTagService do
  let(:actor) { User.first }
  let(:created_locations) { [] }

  def tag(name)
    LocationTag.find_by(name:) ||
      LocationTag.create!(name:, creator: actor.user_id, date_created: Time.current, uuid: SecureRandom.uuid)
  end

  def create_location(tag_name, name, parent: nil)
    location = Location.unscoped.create!(
      name:, parent_location: parent, creator: actor.user_id,
      date_created: Time.current, uuid: SecureRandom.uuid, retired: false
    )
    ActiveRecord::Base.connection.execute(
      'INSERT INTO location_tag_map (location_id, location_tag_id) ' \
      "VALUES (#{location.location_id}, #{tag(tag_name).location_tag_id})"
    )
    created_locations << location
    location.location_id
  end

  let(:authority) { create_location('Traditional Authority', "Spec TA #{SecureRandom.hex(3)}") }
  let(:village_id) { create_location('Village', "Spec Village #{SecureRandom.hex(3)}", parent: authority) }
  let(:village) { Location.unscoped.find(village_id) }

  let(:village_tag_id) { tag('Village').location_tag_id }
  let(:clinic_tag_id) { tag('Village Clinic').location_tag_id }

  before do
    User.current = actor
    # The bare test database ships no location_tag rows, so the tags these
    # examples rely on have to be ensured up front rather than lazily by
    # whichever example happens to run first.
    tag('Village')
    tag('Village Clinic')
  end

  after do
    created_locations.each do |location|
      ActiveRecord::Base.connection.execute("DELETE FROM location_tag_map WHERE location_id = #{location.location_id}")
    end
    # Reverse order: location.parent_location is a self-referencing foreign key.
    created_locations.reverse_each do |location|
      Location.unscoped.where(location_id: location.location_id).delete_all
    end
  end

  def assigned_tag_ids
    LocationTagMap.where(location_id: village_id).pluck(:location_tag_id).sort
  end

  describe 'the whitelist' do
    it 'offers Village Clinic, which exists in location_tag' do
      expect(described_class.assignable_tags.map(&:name)).to eq(['Village Clinic'])
    end

    # The names are resolved, never created - the opposite of
    # LocationsController#find_or_create_location_tag.
    it 'never creates a tag that is missing from the table' do
      stub_const("#{described_class}::ASSIGNABLE_TAG_NAMES", ['No Such Tag'].freeze)

      expect { described_class.assignable_tags.to_a }.not_to change(LocationTag, :count)
      expect(described_class.assignable_tags).to be_empty
    end
  end

  describe '.payload' do
    it 'reports the structural tag as not assignable, so a client renders it read-only' do
      structural = described_class.payload(village)[:tags].find { |t| t[:name] == 'Village' }

      expect(structural[:assignable]).to be(false)
    end

    it 'lists the assignable tags with their current state' do
      clinic = described_class.payload(village)[:assignable_tags].first

      expect(clinic).to include(location_tag_id: clinic_tag_id, name: 'Village Clinic', assigned: false)
    end

    it 'reflects an assignment' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])

      expect(described_class.payload(village)[:assignable_tags].first[:assigned]).to be(true)
    end
  end

  # Backs the tag indicator in the village list: the whole page is resolved in
  # one query, so showing which rows are tagged costs no N+1.
  describe '.assignable_tags_for' do
    let(:other_village_id) { create_location('Village', "Spec Village #{SecureRandom.hex(3)}", parent: authority) }

    it 'returns nothing for an empty list without querying' do
      expect(described_class.assignable_tags_for([])).to eq({})
    end

    it 'keys the tags it finds by location_id' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])

      expect(described_class.assignable_tags_for([village_id, other_village_id]))
        .to eq(village_id => ['Village Clinic'])
    end

    # Absent rather than an empty array: the controller supplies the empty array,
    # which is what tells a client the answer is known and not merely missing.
    it 'omits a location that carries none' do
      expect(described_class.assignable_tags_for([other_village_id])).to eq({})
    end

    # Otherwise the indicator would report a village as a Village Clinic purely
    # because it is a village.
    it 'ignores the structural tags every village carries' do
      expect(described_class.assignable_tags_for([village_id])).to eq({})
    end

    it 'resolves a whole page in a single query' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])
      ids = [village_id, other_village_id]

      count = 0
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
      end
      described_class.assignable_tags_for(ids)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(count).to eq(1)
    end
  end

  describe '.replace_assignable_tags!' do
    it 'adds the tag while leaving the structural tag in place' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])

      expect(assigned_tag_ids).to eq([village_tag_id, clinic_tag_id].sort)
    end

    it 'keeps the village a Village, so it stays visible everywhere it was' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])

      expect(Village.exists?(location_id: village_id)).to be(true)
    end

    it 'removes the tag when it is left out' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])
      described_class.replace_assignable_tags!(village, [])

      expect(assigned_tag_ids).to eq([village_tag_id])
    end

    it 'is idempotent rather than raising on the composite primary key' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])

      expect { described_class.replace_assignable_tags!(village, [clinic_tag_id]) }.not_to raise_error
      expect(assigned_tag_ids).to eq([village_tag_id, clinic_tag_id].sort)
    end

    # A form-encoded empty array reaches Rails as [""], and "".to_i is 0 -- which
    # would be reported as an unassignable tag rather than clearing the set.
    it 'treats a blank entry as no selection rather than tag id 0' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id])

      expect { described_class.replace_assignable_tags!(village, ['']) }.not_to raise_error
      expect(assigned_tag_ids).to eq([village_tag_id])
    end

    it 'accepts ids as strings, which is how they arrive over HTTP' do
      described_class.replace_assignable_tags!(village, [clinic_tag_id.to_s])

      expect(assigned_tag_ids).to include(clinic_tag_id)
    end

    # THE guard. Removing a village's 'Village' tag makes it vanish from every
    # village list while the location row and its user_villages assignments live
    # on, unreachable. A client must not be able to reach it -- not by asking for
    # it, and not by leaving it out of the requested set.
    describe 'the structural tag' do
      it 'cannot be dropped by omitting it' do
        described_class.replace_assignable_tags!(village, [])

        expect(assigned_tag_ids).to eq([village_tag_id])
        expect(Village.exists?(location_id: village_id)).to be(true)
      end

      it 'cannot be requested, and the refusal changes nothing' do
        expect { described_class.replace_assignable_tags!(village, [village_tag_id]) }
          .to raise_error(described_class::UnassignableTagError, /Village/)

        expect(assigned_tag_ids).to eq([village_tag_id])
      end

      it 'names the offending tag in the error rather than failing silently' do
        expect { described_class.replace_assignable_tags!(village, [tag('District').location_tag_id]) }
          .to raise_error(described_class::UnassignableTagError, /District/)
      end
    end

    it 'applies nothing at all when one id in the set is unassignable' do
      expect { described_class.replace_assignable_tags!(village, [clinic_tag_id, village_tag_id]) }
        .to raise_error(described_class::UnassignableTagError)

      expect(assigned_tag_ids).to eq([village_tag_id])
    end
  end
end
