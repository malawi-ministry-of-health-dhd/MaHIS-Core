class RenameArrivaltimeToArrivalTimeInStages < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:stages)
    return unless column_exists?(:stages, :arrivalTime)
    return if column_exists?(:stages, :arrival_time)

    rename_column :stages, :arrivalTime, :arrival_time
  end

  def down
    return unless table_exists?(:stages)
    return unless column_exists?(:stages, :arrival_time)
    return if column_exists?(:stages, :arrivalTime)

    rename_column :stages, :arrival_time, :arrivalTime
  end
end
