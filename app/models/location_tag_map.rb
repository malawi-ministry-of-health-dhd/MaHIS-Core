# frozen_string_literal: true

class LocationTagMap < ApplicationRecord
  self.table_name = :location_tag_map
  self.primary_keys = %i[location_tag_id location_id]

  belongs_to :location_tag, foreign_key: :location_tag_id
  belongs_to :location, foreign_key: :location_id
end
