class Facility < ApplicationRecord
    # Existing Validations
    validates :code, presence: true, uniqueness: true
    validates :name, presence: true
    
    # New Coordinate Validations
    validates :latitude, numericality: { 
      greater_than_or_equal_to: -90,
      less_than_or_equal_to: 90,
      allow_nil: true
    }
    
    validates :longitude, numericality: { 
      greater_than_or_equal_to: -180,
      less_than_or_equal_to: 180,
      allow_nil: true
    }
    
    # Using facility_type instead of type (Rails reserved word)
    alias_attribute :type, :facility_type
    
    # Existing Scopes
    scope :by_district, ->(district) { where(district: district) }
    scope :by_status, ->(status) { where(status: status) }
    
    # New Scope for coordinates
    scope :with_coordinates, -> { where.not(latitude: nil, longitude: nil) }
    
    # Enhanced Helper Methods
    def coordinates
      return nil if latitude.blank? || longitude.blank?
      [latitude.to_f, longitude.to_f]  # Ensure floating point values
    end
    
    def display_name
      common.presence || name
    end
    
    def has_coordinates?
      coordinates.present?
    end
    
    # Enhanced Geospatial Methods
    def distance_to(other_facility)
      return nil unless has_coordinates? && other_facility.has_coordinates?
      
      rad_per_deg = Math::PI/180
      earth_radius = 6371 # km
      
      lat1 = latitude.to_f * rad_per_deg
      lat2 = other_facility.latitude.to_f * rad_per_deg
      lon1 = longitude.to_f * rad_per_deg
      lon2 = other_facility.longitude.to_f * rad_per_deg
      
      dlon = lon2 - lon1
      dlat = lat2 - lat1
      
      a = Math.sin(dlat/2)**2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dlon/2)**2
      c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
      
      (earth_radius * c).round(3) # Round to 3 decimal places
    end
    
    def nearby_facilities(radius_km = 10)
      return [] unless has_coordinates?
      
      # Rough approximation: 1 degree = 111km
      lat_degree_range = radius_km/111.0
      lng_degree_range = radius_km/(111.0 * Math.cos(latitude.to_f * Math::PI/180))
      
      Facility.where.not(id: id)
             .where(latitude: (latitude.to_f - lat_degree_range)..(latitude.to_f + lat_degree_range))
             .where(longitude: (longitude.to_f - lng_degree_range)..(longitude.to_f + lng_degree_range))
             .select { |f| distance_to(f) <= radius_km }
    end
  
    def self.search_by_location(lat, lng, radius_km = 10)
      return none unless lat.present? && lng.present?
      
      lat = lat.to_f
      lng = lng.to_f
      
      # Create temporary facility for distance calculation
      temp_facility = new(latitude: lat, longitude: lng)
      
      # Find facilities within rough square first
      lat_degree_range = radius_km/111.0
      lng_degree_range = radius_km/(111.0 * Math.cos(lat * Math::PI/180))
      
      with_coordinates
        .where(latitude: (lat - lat_degree_range)..(lat + lat_degree_range))
        .where(longitude: (lng - lng_degree_range)..(lng + lng_degree_range))
        .select { |f| temp_facility.distance_to(f) <= radius_km }
    end
  end