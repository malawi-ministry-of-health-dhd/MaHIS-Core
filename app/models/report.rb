# frozen_string_literal: true

class Report < RetirableRecord
  self.table_name = :reporting_report_design

  include Locatable

  belongs_to :type, foreign_key: :report_definition_id, class_name: 'ReportType'
  has_many :values, class_name: 'ReportValue',
                    foreign_key: :report_design_id,
                    dependent: false

  before_destroy :batch_delete_associated_records
  after_void :void_values

  def as_json(options = {})
    super(options.merge(
      include: { type: {}, values: {} }
    ))
  end

  def void_values(reason)
    values.each do |value|
      value.void(reason)
    end
  end

  private

  # Batch delete all drill-down records and report values
  # This prevents N individual DELETE queries
  def batch_delete_associated_records
    return if values.empty?

    value_ids = values.pluck(:id)

    # First delete all drill-down records in batch
    CohortDrillDown.where(reporting_report_design_resource_id: value_ids).delete_all

    # Then delete all report values in batch
    ReportValue.where(id: value_ids).delete_all
  end
end
