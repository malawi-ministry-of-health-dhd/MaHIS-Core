class AddLocationIdToReportingReportDesign < ActiveRecord::Migration[8.1]
  def change
    add_column :reporting_report_design, :location_id, :integer
  end
end
