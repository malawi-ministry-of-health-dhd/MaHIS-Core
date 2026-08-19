# frozen_string_literal: true

# DrugCmsService is a service class for DrugCMS
class DrugCmsService
  def search_drug_cms(kwd, filters = {})
    sql = <<~SQL
      SELECT dc.*
      FROM drug_cms dc
      INNER JOIN arv_drug ad ON ad.drug_id = dc.drug_inventory_id
      WHERE dc.name LIKE '%#{kwd}%' OR dc.code LIKE '%#{kwd}%' OR dc.short_name LIKE '%#{kwd}%'
    SQL

    if filters[:program_id].present?
      sql += " AND dc.program_id = #{ActiveRecord::Base.connection.quote(filters[:program_id])}"
    end
    if filters[:location_id].present?
      sql += " AND dc.location_id = #{ActiveRecord::Base.connection.quote(filters[:location_id])}"
    end

    ActiveRecord::Base.connection.select_all(sql)
  end
end
