# frozen_string_literal: true

# frozen_string_literal = true

require 'rails_helper'
require 'time_utils'

RSpec.describe TimeUtils do
  describe '#calculate age' do
    it 'should be able to calculate a person\s age' do
      birthdate = 25.years.ago
      expected = ((Time.zone.now - birthdate.to_time) / 1.year.seconds).floor
      expect(TimeUtils.get_person_age(birthdate:)).to eq(expected)
    end
  end

  describe '#retro_timestamp' do
    it 'returns nil for nil input' do
      expect(TimeUtils.retro_timestamp(nil)).to be_nil
    end

    it 'returns nil for a blank string instead of raising' do
      expect(TimeUtils.retro_timestamp('')).to be_nil
    end

    it 'returns a timestamp for a valid date string' do
      expect(TimeUtils.retro_timestamp('2026-07-01')).to be_a(Time)
    end
  end
end
