class AddFacilityCodeToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :facility_code, :string, default: nil

    add_foreign_key :users, :facilities, column: :facility_code,
                                         primary_key: :code
  end
end

