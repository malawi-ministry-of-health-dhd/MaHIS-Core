def mahis_user_role_from_source(source_role)
  MasHISCoreDB.connection.select_one <<~SQL
    SELECT role 
    FROM user_role
    WHERE role = #{quote(source_role)}
  SQL
end

def user_role_has_changed?(user_role)
  val = MasHISCoreDB.connection.select_one <<~SQL
    SELECT 1 
      FROM user_role 
      WHERE role = #{quote(user_role.role)}
  SQL
  !val.present?
end

def load_user_roles_file
  data = CSV.read(Rails.root.join('db', 'data', 'old_user_roles.csv'), headers: true)
  # convert to OpenStruct
  data.map { |row| OpenStruct.new(row.to_h) }
end

def user_role_moved_to(user_role)
  # find role with the old name else create one
  role_in_mahis = Role.find_by_role(user_role.role&.strip)
  if role_in_mahis.present?
    return OpenStruct.new(role: role_in_mahis.role)
  end

  # create a new role first
  new_role = Role.create(
    role: user_role.role,
    uuid: SecureRandom.uuid
  )
  new_role.reload

  OpenStruct.new(role: new_role.role)
end


def remap_user_roles
  ActiveRecord::Base.transaction do
    load_user_roles_file.each do |user_role|
      if user_role_has_changed?(user_role)
        moved_user_role = user_role_moved_to(user_role)
        
        log "UserRole #{user_role.role} has changed to #{moved_user_role.role}"
        
        update_references(user_role, moved_user_role, 'user_roles')
      end
    end
  rescue StandardError => e
    puts e.message
    raise ActiveRecord::Rollback
  end
end
