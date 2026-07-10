class AddReferringProgramIdToStages < ActiveRecord::Migration[7.0]
  def change
    add_column :stages, :referring_program_id, :integer unless column_exists?(:stages, :referring_program_id)
  end
end
