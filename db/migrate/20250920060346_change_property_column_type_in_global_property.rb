class ChangePropertyColumnTypeInGlobalProperty < ActiveRecord::Migration[7.0]
  def up
    remove_index :global_property, name: "idx_global_property_property_location"

    add_column :global_property, :property_tmp, :string, limit: 255

    execute <<-SQL.squish
      UPDATE global_property
      SET property_tmp = CONVERT(property USING utf8mb4)
    SQL

    remove_column :global_property, :property

    rename_column :global_property, :property_tmp, :property

    add_index :global_property, [:property, :location_id], unique: true, name: "idx_global_property_property_location"
  end

  def down
    remove_index :global_property, name: "idx_global_property_property_location"

    add_column :global_property, :property_tmp, :binary, limit: 255
    execute <<-SQL.squish
      UPDATE global_property
      SET property_tmp = property
    SQL
    remove_column :global_property, :property
    rename_column :global_property, :property_tmp, :property

    add_index :global_property, [:property, :location_id], unique: true, name: "idx_global_property_property_location"
  end
end
