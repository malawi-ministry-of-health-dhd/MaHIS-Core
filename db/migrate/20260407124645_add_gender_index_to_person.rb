class AddGenderIndexToPerson < ActiveRecord::Migration[8.1]
  def change
    add_index :person, :gender, name: 'person_gender_idx'
  end
end
