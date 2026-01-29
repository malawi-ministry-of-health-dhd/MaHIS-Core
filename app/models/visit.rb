class Visit < ApplicationRecord
    belongs_to :patient, foreign_key: 'patientId', primary_key: 'patient_id'
    validates :patientId, presence: true
    validates :startDate, presence: true
    validates :programId, presence: true

    has_many :stages
    belongs_to :location, optional: true   
    belongs_to :encounter
end   
