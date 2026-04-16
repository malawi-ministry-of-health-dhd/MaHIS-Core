# frozen_string_literal: true

class RoleRole < ApplicationRecord
  self.table_name = 'role_role'
  self.primary_key = %i[parent_role child_role]
end
