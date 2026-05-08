class FixTptOrderConceptIds < ActiveRecord::Migration[8.1]
  TPT_DRUG_NAMES = %w[Isoniazid Rifapentine Isoniazid/Rifapentine].freeze

  def up
    # Use the drug table as the source of truth for concept_id.
    # This fixes any orders whose concept_id was synced incorrectly
    # by updating it to match the concept_id on the corresponding drug record.
    execute <<~SQL
      UPDATE orders o
      INNER JOIN drug_order do2
        ON do2.order_id = o.order_id
      INNER JOIN drug d
        ON d.drug_id = do2.drug_inventory_id
      INNER JOIN concept_name cn
        ON cn.concept_id = d.concept_id
        AND cn.name IN (#{TPT_DRUG_NAMES.map { |n| ActiveRecord::Base.connection.quote(n) }.join(', ')})
      SET o.concept_id = d.concept_id
      WHERE o.concept_id != d.concept_id
    SQL

    say_with_time 'Fixed TPT order concept_ids' do
      affected = ActiveRecord::Base.connection.exec_update(<<~SQL)
        SELECT ROW_COUNT()
      SQL
      affected
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Cannot reverse concept_id fix — original (incorrect) values are not stored'
  end
end
