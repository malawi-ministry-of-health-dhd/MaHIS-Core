# app/services/facility_service.rb
class FacilityService
    def initialize(params = {})
      @params = params
    end
  
    def list_facilities
      facilities = Location.all
  
      facilities = apply_name_filter(facilities)
      facilities = apply_district_filter(facilities)
      facilities = apply_district_name_filter(facilities)
      facilities = apply_status_filter(facilities)
      facilities = apply_location_filter(facilities)
      facilities = apply_sorting(facilities)
  
      {
        facilities: facilities,
        total: facilities.size,
        filters_applied: filters_applied
      }
    end

    def list_districts
      # Use a subquery to get distinct districts
      Facility.select('district')
              .distinct
              .order(:district)
              .map.with_index do |facility, index|
        {
          id: index + 1,  # Incremental ID starting from 1
          name: facility.district,
          display_name: facility.district
        }
      end.compact
    end

    # Fetch facilities by district_name
    def list_facilities_by_district(district_name)
      sanitized_district_name = district_name.to_s.gsub('?', '')

      facilities = Location.where(city_village: sanitized_district_name)
      # facilities = Facility.where(district: sanitized_district_name)

      {
        facilities: facilities,
        total: facilities.count,
        filters_applied: { district_name: sanitized_district_name }
      }
    end

  
    def find_nearby_facilities(location_id)
      facility = Location.find(location_id)
      radius = @params[:radius].present? ? @params[:radius].to_f : 10
  
      nearby = facility.nearby_facilities(radius)
      nearby = filter_nearby_facilities(nearby)
  
      {
        facilities: nearby,
        total: nearby.size,
        center_facility: facility
      }
    end

    def list_facility_codes
      # Get all unique location uuids ordered alphabetically
      uuids = Location.select('uuid')
                     .distinct
                     .order(:uuid)
                     .map do |location|
        {
          uuid: location.uuid,
          name: Location.find_by(uuid: location.uuid)&.name
        }
      end.compact
  
      {
        location_uuids: uuids,
        total: uuids.size
      }
    end
  
    private
  
    def apply_name_filter(facilities)
      return facilities unless @params[:name].present?
  
      name_query = "%#{@params[:name]}%"
      facilities.where("name ILIKE ? OR common ILIKE ?", name_query, name_query)
    end
  
    def apply_district_filter(facilities)
      return facilities unless @params[:city_village].present?
  
      facilities.by_district(@params[:city_village])
    end
  
    def apply_district_name_filter(facilities)
      return facilities unless @params[:district_name].present?
  
      district_query = "%#{@params[:district_name]}%"
      facilities.where("city_village ILIKE ?", district_query)
    end
  
    def apply_status_filter(facilities)
      return facilities unless @params[:status].present?
  
      facilities.by_status(@params[:status])
    end
  
    def apply_location_filter(facilities)
      return facilities unless @params[:latitude].present? && @params[:longitude].present?
  
      radius = @params[:radius].present? ? @params[:radius].to_f : 10
      Facility.search_by_location(
        @params[:latitude],
        @params[:longitude],
        radius
      )
    end
  
    def apply_sorting(facilities)
      case @params[:sort_by]
      when 'name'
        facilities.order('name ASC')
      when 'district'
        facilities.order('district ASC, name ASC')
      when 'created'
        facilities.order('created_at DESC')
      else
        facilities.order('name ASC')
      end
    end
  
    def filter_nearby_facilities(facilities)
      facilities = filter_by_name(facilities)
      facilities = filter_by_district_name(facilities)
      facilities
    end
  
    def filter_by_name(facilities)
      return facilities unless @params[:name].present?
  
      facilities.select do |f|
        f.name.downcase.include?(@params[:name].downcase) ||
          (f.common && f.common.downcase.include?(@params[:name].downcase))
      end
    end
  
    def filter_by_district_name(facilities)
      return facilities unless @params[:district_name].present?
  
      district_query = @params[:district_name].downcase
      facilities.select { |f| f.district&.downcase&.include?(district_query) }
    end
  
    def filters_applied
      {
        name: @params[:name],
        district: @params[:district],
        district_name: @params[:district_name],
        status: @params[:status],
        latitude: @params[:latitude],
        longitude: @params[:longitude],
        radius: @params[:radius],
        sort_by: @params[:sort_by]
      }.compact
    end
  end