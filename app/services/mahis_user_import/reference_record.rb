# frozen_string_literal: true

module MahisUserImport
  ReferenceRecord = Struct.new(
    :role,
    :program_id,
    :name,
    :location_id,
    :parent_location,
    :retired,
    keyword_init: true
  )
end
