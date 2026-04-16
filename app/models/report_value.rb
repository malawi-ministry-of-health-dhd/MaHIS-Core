# frozen_string_literal: true

class ReportValue < RetirableRecord
  self.table_name = :reporting_report_design_resource

  include Locatable

  belongs_to :report, foreign_key: :report_design_id
  has_many :drill_down_records,
           class_name: 'CohortDrillDown',
           foreign_key: :reporting_report_design_resource_id,
           dependent: :delete_all

  validates_presence_of :name
end
