# frozen_string_literal: true

require 'utils/remappable_hash'
require 'zebra_printer/init'

module Api
  module V1
    class LocationsController < ApplicationController
      skip_before_action :authenticate, only: %i[print_label current_facility]

      # Retrieve all locations
      #
      # GET /locations
      #
      # Optional parameters (filters):
      #   name - Filter locations having this name
      #   tag - Filter locations having a tag matching this
      def index
        # 1. Clean and standardize all inputs
        name = params[:name].to_s.strip
        tag = params[:tag].to_s.strip
        city_village = params[:city_village].to_s.strip
        district = params[:district].to_s.strip
        parent_id = params[:parent_id].to_s.strip

        # 2. Start the query scope
        # We use 'where(retired: false)' because your logs show this is the system standard
        locations = Location.includes(:location_attributes).where(retired: false)

        # 3. Apply Geography filters (Direct columns)
        locations = locations.where('name LIKE ?', "%#{name}%") if name.present?
        locations = locations.where('city_village LIKE ?', "%#{city_village}%") if city_village.present?
        locations = locations.where('county_district LIKE ?', "%#{district}%") if district.present?
        locations = locations.where('location.parent_location = ?', "#{parent_id}") if parent_id.present?

        # 4. Apply Functional filter (Tags via Join)
        # We only call this once to avoid SQL join conflicts
        locations = filter_locations_by_tag(locations, tag) if tag.present?

        # 5. Apply Ordering and Pagination
        locations = paginate(locations.order(:name))

        # 6. Render with eager-loaded attributes
        render json: locations, include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      end

      # Retrieve single location by its id
      #
      # GET /locations/:id
      def show
        # Eager load location_attributes for the single record
        location = Location.includes(:location_attributes).find_by(location_id: params[:id])

        # Pass 'include' option to trigger custom as_json and define fields
        render json: location, include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      end

      # Using Legacy Location ID location_attribute_type
      def show_legacy_location
        legacy_location_id = params[:id]
        location_attribute_type_id = LocationAttributeType.find_by(name: 'Legacy Location ID').location_attribute_type_id

        location_attribute = LocationAttribute.find_by(
          attribute_type_id: location_attribute_type_id,
          value_reference: legacy_location_id
        )

        if location_attribute
          location = Location.find(location_attribute.location_id)
          render json: location, include: {
            location_attributes: {
              only: %i[location_attribute_id attribute_type_id value_reference]
            }
          }
        else
          # Just fallback to trying to find using any location
          location = Location.includes(:location_attributes).find_by(location_id: legacy_location_id)
          render json: location, include: {
            location_attributes: {
              only: %i[location_attribute_id attribute_type_id value_reference]
            }
          }
        end
      end

      # Retrieve the current configured facility
      #
      # GET /locations/current_facility
      def current_facility
        render json: Location.current_health_center
      end

      def create
        # Require and permit parameters
        params.require(:parent_id)
        params.require(:tag)
        params.require(:name)
        location_params = params.permit(:name, :description, :address1, :address2, :district,
                                        :parent_id, :tag, :city_village, :county_district)

        # Build location attributes
        location_attrs = {
          name: location_params[:name],
          description: location_params[:description],
          address1: location_params[:address1],
          address2: location_params[:address2],
          city_village: location_params[:city_village] || location_params[:district],
          county_district: location_params[:county_district] || location_params[:district],
          creator: User.current.id,
          date_created: Time.now
        }

        # Add parent location
        parent_location = Location.find_by(location_id: location_params[:parent_id])
        return render json: { error: 'Parent location not found' }, status: :bad_request unless parent_location

        location_attrs[:parent_location] = parent_location.location_id

        location = Location.create(location_attrs)

        if location.errors.any?
          render json: location.errors, status: :bad_request
        else
          # Create location tag mapping
          tag = find_or_create_location_tag(location_params[:tag])
          return render json: { error: 'Failed to create or find tag' }, status: :bad_request unless tag

          LocationTagMap.create(
            location_id: location.location_id,
            location_tag_id: tag.location_tag_id
          )

          # Reload to include associations
          location.reload
          render json: location, include: {
            location_attributes: {
              only: %i[location_attribute_id attribute_type_id value_reference]
            }
          }
        end
      rescue ActionController::ParameterMissing => e
        render json: { error: e.message }, status: :bad_request
      end

      # GET /locations/districts
      def districts
        # Fetch unique, non-blank districts sorted alphabetically
        unique_names = Location.where.not(county_district: [nil, ''])
                               .distinct
                               .order(:county_district)
                               .pluck(:county_district)

        # Map to objects with an ascending counter starting at 1
        formatted_districts = unique_names.each_with_index.map do |name, index|
          {
            id: index + 1,
            name: name
          }
        end

        render json: formatted_districts
      end

      def print_label
        location = location_to_print

        return render json: 'location_id or location_name required', status: :bad_request unless location

        render_zpl(service.print_location_label(location))
      end

      private

      def find_or_create_location_tag(tag_param)
        # Try to find by ID first if it's numeric
        if tag_param.to_s.match?(/^\d+$/)
          tag = LocationTag.find_by(location_tag_id: tag_param, retired: false)
          return tag if tag
        end

        # Otherwise find or create by name
        LocationTag.find_or_create_by(name: tag_param) do |new_tag|
          new_tag.creator = User.current.id
          new_tag.date_created = Time.now
          new_tag.retired = false
        end
      end

      def filter_locations_by_tag(locations, tag)
        location_tag_id = LocationTag.where('name like ?', "%#{tag}%")[0].id
        location_tag_maps = LocationTagMap.where(location_tag_id:)
        locations.joins(:tag_maps).merge(location_tag_maps)
      end

      def location
        Location.find(params[:id])
      end

      def service
        LocationService.new
      end

      # Helper for print label method that returns a location to be printed
      def location_to_print
        if params[:location_id]
          Location.find(params[:location_id])
        elsif params[:location_name]
          Location.find_by_name(params[:location_name])
        end
      end
    end
  end
end
