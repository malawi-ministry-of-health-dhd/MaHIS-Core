# frozen_string_literal: true

class UserClinicAssignment < ApplicationRecord
  self.table_name = :user_clinic_assignments
  self.primary_key = :user_clinic_assignment_id

  belongs_to :user, foreign_key: :user_id, primary_key: :user_id, optional: false
  belongs_to :location, foreign_key: :location_id, primary_key: :location_id, optional: true

  scope :active, -> { where(retired: 0) }
  scope :inactive, -> { where(retired: 1) }
end
