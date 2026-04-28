# frozen_string_literal: true

module Api
  module V1
    class FacilitiesController < ApplicationController
      def index
        filters = params.permit(%i[district name location_id paginate page page_size])
        district, name, location_id = filters.values_at(:district, :name, :location_id)

        facilities = facilities_scope
        facilities = facilities.where(location_id: location_id) if location_id.present?
        facilities = facilities.where('location.name LIKE ?', "%#{name}%") if name.present?

        if district.present?
          facilities = facilities.where(
            'location.city_village LIKE :district OR location.county_district LIKE :district',
            district: "%#{district}%"
          )
        end

        total_count = facilities.distinct.count(:location_id)
        page = (params[:page] || 1).to_i
        page_size = (params[:page_size] || DEFAULT_PAGE_SIZE).to_i
        paginated_data = paginate(facilities.order(:name))

        render json: {
          data: paginated_data,
          count: paginated_data.length,
          total_count: total_count,
          pagination: {
            current_page: params[:paginate] == 'false' ? 1 : page,
            per_page: params[:paginate] == 'false' ? total_count : page_size,
            total_count: total_count,
            total_pages: params[:paginate] == 'false' ? 1 : (total_count / page_size.to_f).ceil
          }
        }, include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      end

      def districts
        districts = facilities_scope
                    .includes(:parent)
                    .map do |facility|
                      district_name = facility.parent&.name || facility.city_village || facility.county_district
                      next if district_name.blank?

                      {
                        district_id: facility.parent&.location_id,
                        name: district_name
                      }
                    end
                    .compact
                    .uniq { |item| [item[:district_id], item[:name]] }
                    .sort_by { |item| item[:name] }

        render json: {
          data: districts,
          count: districts.length,
          total_count: districts.length
        }
      end

      def nearby
        facility = facilities_scope.find_by(location_id: params[:id])
        return render json: { error: 'Facility not found' }, status: :not_found unless facility

        radius_km = params[:radius_km].presence || 10
        nearby_facilities = facility.nearby_facilities(radius_km.to_f)

        render json: nearby_facilities, include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      end

      private

      def facilities_scope
        Location.includes(:parent, :location_attributes)
                .where(retired: false)
                .where(parent_location: District.select(:location_id))
                .where.not(name: [nil, ''])
                .where.not(city_village: [nil, ''])
                .distinct
      end
    end
  end
end
