class AddLocationIdToStagesAndVisitTable < ActiveRecord::Migration[7.0]
  def change
    add_column :visits, :location_id, :bigint, null: false
    add_column :stages, :location_id, :bigint, null: false
  end
end
