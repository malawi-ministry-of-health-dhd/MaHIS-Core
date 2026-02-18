class CreateStages < ActiveRecord::Migration[7.0]
  def change
    unless table_exists?(:stages)
      create_table :stages do |t|
        t.integer :visit_id, null: false
        t.integer :patient_id, null: false
        t.integer :location_id
        t.integer :program_id
        t.string :stage
        t.datetime :arrivalTime, precision: 6
        t.boolean :status
        t.string :disposition_type
        t.string :triage_result
        t.integer :visit_number
        t.string :patient_care_area
        t.string :department
        t.string :destination

        t.timestamps precision: 6, null: false
      end
    end

    change_column :stages, :visit_id, :integer unless column_exists?(:stages, :visit_id, :integer)

    add_foreign_key :stages, :visit, column: :visit_id, primary_key: :visit_id unless foreign_key_exists?(:stages,
                                                                                                         :visit,
                                                                                                         column: :visit_id)
    add_foreign_key :stages, :patient, column: :patient_id, primary_key: :patient_id unless foreign_key_exists?(:stages,
                                                                                                                 :patient,
                                                                                                                 column: :patient_id)
    add_foreign_key :stages, :location, column: :location_id, primary_key: :location_id unless foreign_key_exists?(:stages,
                                                                                                                    :location,
                                                                                                                    column: :location_id)
    add_index :stages, :visit_id unless index_exists?(:stages, :visit_id)
    add_index :stages, :patient_id unless index_exists?(:stages, :patient_id)
    add_index :stages, :location_id unless index_exists?(:stages, :location_id)
    add_index :stages, :status unless index_exists?(:stages, :status)
    add_index :stages, :stage unless index_exists?(:stages, :stage)
    add_index :stages, :visit_number unless index_exists?(:stages, :visit_number)
  end
end
