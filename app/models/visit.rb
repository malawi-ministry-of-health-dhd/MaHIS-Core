class Visit < ApplicationRecord
  self.table_name = 'visit'
  self.primary_key = 'visit_id'

  audited

  belongs_to :patient, foreign_key: 'patient_id', primary_key: 'patient_id'
  belongs_to :visit_type, foreign_key: 'visit_type_id', primary_key: 'visit_type_id', optional: true
  belongs_to :location, foreign_key: 'location_id', primary_key: 'location_id', optional: true
  belongs_to :creator_user, class_name: 'User', foreign_key: 'creator', primary_key: 'user_id', optional: true
  belongs_to :changed_by_user, class_name: 'User', foreign_key: 'changed_by', primary_key: 'user_id', optional: true
  belongs_to :voided_by_user, class_name: 'User', foreign_key: 'voided_by', primary_key: 'user_id', optional: true

  has_many :encounters, foreign_key: 'visit_id', primary_key: 'visit_id'
  has_many :stages, foreign_key: 'visit_id', primary_key: 'visit_id'

  validates :patient_id, presence: true
  validates :date_started, presence: true
  validates :visit_type_id, presence: true
end   
