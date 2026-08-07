# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DdeMergingService do
  describe '#matching_observation' do
    it 'safely compares observation text containing an apostrophe' do
      observation = Observation.new(
        concept_id: 1,
        obs_datetime: Time.zone.parse('2025-01-01 10:00:00'),
        value_text: "don't know"
      )

      expect do
        described_class.new(nil, nil).send(:matching_observation, -999_999, observation)
      end.not_to raise_error
    end
  end
end
