class AddCompositeNameIndexesToPersonName < ActiveRecord::Migration[8.1]
  def change
    # Composite indexes allow MySQL to use voided=0 equality + LIKE prefix range
    # scan on a single index path instead of hitting the name index then doing
    # a table lookup to check voided.
    add_index :person_name, %i[voided given_name],  name: 'person_name_voided_given_name_idx'
    add_index :person_name, %i[voided family_name], name: 'person_name_voided_family_name_idx'
    add_index :person_name, %i[voided middle_name], name: 'person_name_voided_middle_name_idx'
  end
end
