# frozen_string_literal: true

class TraditionalAuthority < RetirableRecord
  self.table_name = :location
  self.primary_key = :location_id

  has_one :location_tag_map, foreign_key: :location_id
  belongs_to :district, foreign_key: :parent_location
  has_many :villages, foreign_key: :parent_location

  validates :name, presence: true
  validates :parent_location, presence: true

  default_scope do
    where(
      location_id: LocationTagMap
        .where(location_tag_id: LocationTag.where(name: 'Traditional Authority').select(:location_tag_id))
        .select(:location_id)
    )
  end

  def as_json(options = {})
    super(options.merge(
      methods: %i[traditional_authority_id district_id district_name]
    ))
  end

  def traditional_authority_id
    self.location_id
  end

  def district_id
    parent_location
  end

  def district_name
    district&.county_district
  end
end
