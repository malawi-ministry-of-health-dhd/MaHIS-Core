def mahis_order_type_from_source(source_order_type_id)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT order_type_id, name 
    FROM order_type
    WHERE order_type_id = #{source_order_type_id}
  SQL
end

def order_type_has_changed?(order_type)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM order_type 
      WHERE order_type_id = #{order_type.order_type_id} 
    AND name = #{quote(order_type.name)}
  SQL
  !val.present?
end

def load_order_types_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_order_types.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def order_type_moved_to(order_type)
  # find order_type with the old name else create one
  order_type_in_mahis = OrderType.find_by_name(order_type.name&.strip)
  if order_type_in_mahis.present?
    return OpenStruct.new(order_type_id: order_type_in_mahis.order_type_id, name: order_type_in_mahis.name)
  end

  # create a new order_type
  new_order_type = OrderType.create(
    name: order_type.name,
    creator: @creator,
    date_created: Time.now,
    uuid: SecureRandom.uuid
  )
  new_order_type.reload

  OpenStruct.new(order_type_id: new_order_type.order_type_id, name: order_type.name)
end


def remap_order_types
  ActiveRecord::Base.transaction do
    load_order_types_file.each do |order_type|
      if order_type_has_changed?(order_type)
        moved_order_type = order_type_moved_to(order_type)
        
        log "OrderType #{order_type.order_type_id} (#{order_type.name}) has changed to #{moved_order_type.order_type_id} (#{moved_order_type.name})"
        
        update_references(order_type, moved_order_type, 'order_types')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
