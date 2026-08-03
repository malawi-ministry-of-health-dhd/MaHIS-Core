# frozen_string_literal: true

FactoryBot.define do
  factory :order do
    association :concept
    association :order_type
    association :encounter
    association :patient
    provider { User.current || User.unscoped.first }
    orderer { provider&.user_id }
    creator { 1 }
  end
end
