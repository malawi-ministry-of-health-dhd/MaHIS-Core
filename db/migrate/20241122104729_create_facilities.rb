class CreateFacilities < ActiveRecord::Migration[7.0]
  def change
    create_table :facilities do |t|
      t.string :code, null: false
      t.string :name, null: false
      t.string :common
      t.string :ownership
      t.string :facility_type  # Renamed from type for Rails compatibility
      t.string :status
      t.string :regulatory_status
      t.string :district
      t.date :date_opened
      t.string :latitude
      t.string :longitude

      t.timestamps

      t.index :code, unique: true
    end
  end
end
