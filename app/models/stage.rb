class Stage < ApplicationRecord
    belongs_to :visit, foreign_key: :visit_id, primary_key: :visit_id
    belongs_to :patient, foreign_key: :patient_id, primary_key: :patient_id
    belongs_to :location, foreign_key: :location_id, primary_key: :location_id, optional: true

    VALID_STAGES = %w[VITALS CONSULTATION LAB DISPENSATION].freeze

    validates :status, inclusion: { in: [true, false], message: "must be true or false" }
    validates :patient_id, :arrivalTime, :visit_id, :stage, presence: true
    validates :stage, inclusion: { in: VALID_STAGES, message: "%{value} is not a valid stage" }
end
  
