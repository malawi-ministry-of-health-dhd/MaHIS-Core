# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SecurityQuestionService do
  let(:user) do
    User.create!(
      username: "sq_#{SecureRandom.hex(4)}",
      password: UserService.hash_password('x', 'salty'), salt: 'salty',
      person: create(:person), creator: User.first.user_id
    )
  end

  let(:entries) do
    [
      { question_id: 'birth_village', answer: 'Nkhulambe' },
      { question_id: 'home_district', answer: 'Blantyre' },
      { question_id: 'mother_maiden_name', answer: 'Banda' }
    ]
  end

  after { described_class.clear!(user) }

  describe 'the catalogue' do
    it 'offers ten questions to choose three from' do
      expect(described_class.catalogue.size).to eq(10)
      expect(described_class::REQUIRED_ANSWERS).to eq(3)
    end

    it 'gives every question a stable id and text' do
      described_class.catalogue.each do |question|
        expect(question[:id]).to be_present
        expect(question[:text]).to be_present
      end
      expect(described_class.catalogue.map { |q| q[:id] }.uniq.size).to eq(10)
    end
  end

  describe 'saving' do
    it 'stores the chosen questions and reports them back' do
      selected = described_class.save!(user, entries)

      expect(selected.map { |q| q[:id] }).to eq(%w[birth_village home_district mother_maiden_name])
      expect(described_class).to be_configured(user)
    end

    it 'never stores the answer itself' do
      described_class.save!(user, entries)

      raw = UserProperty.find_by(user_id: user.user_id, property: described_class::ANSWERS_PROPERTY).property_value

      expect(raw).not_to include('Nkhulambe')
      expect(raw).not_to include('nkhulambe')
      expect(raw).to include(UserService.hash_password('nkhulambe', user.salt))
    end

    it 'hashes answers the same way passwords are hashed' do
      described_class.save!(user, entries)

      stored = JSON.parse(UserProperty.find_by(user_id: user.user_id, property: described_class::ANSWERS_PROPERTY).property_value)

      expect(stored.first['answer']).to eq(Digest::SHA512.hexdigest("nkhulambe#{user.salt}"))
    end

    it 'replaces a previous set rather than adding to it' do
      described_class.save!(user, entries)
      described_class.save!(user, [
                             { question_id: 'first_animal', answer: 'Bingo' },
                             { question_id: 'childhood_food', answer: 'Nsima' },
                             { question_id: 'family_market', answer: 'Limbe' }
                           ])

      expect(described_class.questions_for(user).map { |q| q[:id] }).to eq(%w[first_animal childhood_food family_market])
      expect(UserProperty.where(user_id: user.user_id, property: described_class::ANSWERS_PROPERTY).count).to eq(1)
    end

    it 'refuses fewer than three questions' do
      expect { described_class.save!(user, entries.take(2)) }
        .to raise_error(SecurityQuestionService::InvalidAnswers, /exactly 3/)
    end

    it 'refuses the same question three times' do
      repeated = Array.new(3) { { question_id: 'birth_village', answer: 'Nkhulambe' } }

      expect { described_class.save!(user, repeated) }
        .to raise_error(SecurityQuestionService::InvalidAnswers, /three different/)
    end

    it 'refuses a question that is not in the catalogue' do
      tampered = entries.dup
      tampered[0] = { question_id: 'favourite_password', answer: 'hunter2' }

      expect { described_class.save!(user, tampered) }
        .to raise_error(SecurityQuestionService::InvalidAnswers, /Unknown question/)
    end

    it 'refuses a one-character answer' do
      tampered = entries.dup
      tampered[0] = { question_id: 'birth_village', answer: 'N' }

      expect { described_class.save!(user, tampered) }
        .to raise_error(SecurityQuestionService::InvalidAnswers, /at least/)
    end

    it 'refuses a blank answer' do
      tampered = entries.dup
      tampered[0] = { question_id: 'birth_village', answer: '   ' }

      expect { described_class.save!(user, tampered) }.to raise_error(SecurityQuestionService::InvalidAnswers)
    end
  end

  describe 'verifying' do
    before { described_class.save!(user, entries) }

    it 'accepts the exact answers' do
      expect(described_class.verify(user, entries)).to be(true)
    end

    it 'ignores case and surrounding spacing' do
      shouted = entries.map { |entry| { question_id: entry[:question_id], answer: "  #{entry[:answer].upcase}  " } }

      expect(described_class.verify(user, shouted)).to be(true)
    end

    it 'accepts the answers in any order' do
      expect(described_class.verify(user, entries.reverse)).to be(true)
    end

    it 'rejects when one answer is wrong' do
      wrong = entries.dup
      wrong[1] = { question_id: 'home_district', answer: 'Lilongwe' }

      expect(described_class.verify(user, wrong)).to be(false)
    end

    it 'rejects when only some questions are answered' do
      expect(described_class.verify(user, entries.take(2))).to be(false)
    end

    it 'rejects a user who has set no questions' do
      other = User.create!(username: "sq_none_#{SecureRandom.hex(4)}", password: 'x', salt: 'salty',
                           person: create(:person), creator: User.first.user_id)

      expect(described_class.verify(other, entries)).to be(false)
    end

    it 'is not fooled by answering a question the user did not choose' do
      swapped = [
        { question_id: 'birth_village', answer: 'Nkhulambe' },
        { question_id: 'home_district', answer: 'Blantyre' },
        { question_id: 'childhood_food', answer: 'Banda' }
      ]

      expect(described_class.verify(user, swapped)).to be(false)
    end
  end

  describe 'the reset token' do
    before { described_class.save!(user, entries) }

    it 'returns a token that identifies the user' do
      issued = described_class.issue_reset_token!(user)

      expect(described_class.consume_reset_token!(issued[:token])).to eq(user)
    end

    it 'stores only the token hash, never the token' do
      issued = described_class.issue_reset_token!(user)
      raw = UserProperty.find_by(user_id: user.user_id, property: described_class::RESET_PROPERTY).property_value

      expect(raw).not_to include(issued[:token])
    end

    it 'can only be spent once' do
      issued = described_class.issue_reset_token!(user)
      described_class.consume_reset_token!(issued[:token])

      expect(described_class.consume_reset_token!(issued[:token])).to be_nil
    end

    # Ages the stored row rather than travelling in time, which needs a
    # test-helper this suite does not include globally.
    def expire_reset_token!(expires_at)
      property = UserProperty.find_by(user_id: user.user_id, property: described_class::RESET_PROPERTY)
      payload = JSON.parse(property.property_value)
      payload['expires_at'] = expires_at
      property.update!(property_value: payload.to_json)
    end

    it 'is refused once expired' do
      issued = described_class.issue_reset_token!(user)
      expire_reset_token!(1.minute.ago.iso8601)

      expect(described_class.consume_reset_token!(issued[:token])).to be_nil
    end

    it 'treats an unreadable expiry as expired rather than as valid forever' do
      issued = described_class.issue_reset_token!(user)
      expire_reset_token!('not-a-timestamp')

      expect(described_class.consume_reset_token!(issued[:token])).to be_nil
    end

    it 'still spends an expired token, so it cannot be retried' do
      issued = described_class.issue_reset_token!(user)
      expire_reset_token!(1.minute.ago.iso8601)
      described_class.consume_reset_token!(issued[:token])

      expect(UserProperty.where(user_id: user.user_id, property: described_class::RESET_PROPERTY)).to be_empty
    end

    it 'refuses a blank or unknown token' do
      expect(described_class.consume_reset_token!(nil)).to be_nil
      expect(described_class.consume_reset_token!('')).to be_nil
      expect(described_class.consume_reset_token!('not-a-real-token')).to be_nil
    end
  end

  describe 'clearing' do
    it 'removes the answers and any live reset token' do
      described_class.save!(user, entries)
      described_class.issue_reset_token!(user)

      described_class.clear!(user)

      expect(described_class).not_to be_configured(user)
      expect(UserProperty.where(user_id: user.user_id, property: described_class::PROTECTED_PROPERTIES)).to be_empty
    end
  end
end
