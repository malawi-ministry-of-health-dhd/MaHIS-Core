# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonService do
  describe '#safe_person_trunk_params' do
    subject(:service) { described_class.new }

    let(:person) do
      instance_double(
        Person,
        gender: 'F',
        birthdate: Date.new(1990, 1, 2),
        birthdate_estimated: 0
      )
    end

    it 'preserves existing demographics when an offline edit sends blank values' do
      updates = service.safe_person_trunk_params(
        person,
        gender: '', birthdate: nil, birthdate_estimated: ''
      )

      expect(updates).to eq({})
    end

    it 'allows complete demographic corrections' do
      updates = service.safe_person_trunk_params(
        person,
        gender: 'M', birthdate: '1991-03-04', birthdate_estimated: false
      )

      expect(updates).to eq(
        gender: 'M', birthdate: '1991-03-04', birthdate_estimated: false
      )
    end
  end
end
