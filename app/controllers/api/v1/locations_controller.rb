# frozen_string_literal: true

require 'utils/remappable_hash'
require 'zebra_printer/init'
require 'securerandom'

module Api
  module V1
    class LocationsController < ApplicationController
      FACILITY_LEVEL_ATTRIBUTE = 'Facility Level'
      FACILITY_TYPE_ATTRIBUTE = 'Facility Type'
      ALLOWED_FACILITY_LEVELS = %w[Primary Secondary Tertiary].freeze

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

      # GET /locations/:id/facility_level
      # PUT /locations/:id/facility_level
      # PATCH /locations/:id/facility_level
      def facility_level
        location = Location.find_by(location_id: params[:id])
        return render json: { error: 'Location not found' }, status: :not_found unless location

        unless authorized_for_location?(location.location_id)
          return render json: { error: 'Location is out of your authorized scope' }, status: :forbidden
        end

        if request.get?
          current_level = facility_level_for_location(location.location_id)
          return render json: {
            location_id: location.location_id,
            facility_level: current_level,
            allowed_levels: ALLOWED_FACILITY_LEVELS
          }
        end

        level = normalize_facility_level(params[:facility_level])
        return render json: { error: "facility_level must be one of: #{ALLOWED_FACILITY_LEVELS.join(', ')}" },
                      status: :unprocessable_entity if level.blank?

        attribute_type_id = LocationAttributeType.where(name: FACILITY_LEVEL_ATTRIBUTE).pick(:location_attribute_type_id)
        return render json: { error: "'#{FACILITY_LEVEL_ATTRIBUTE}' attribute type not found" },
                      status: :unprocessable_entity if attribute_type_id.blank?

        location_attribute = LocationAttribute.where(
          location_id: location.location_id,
          attribute_type_id: attribute_type_id
        ).where(voided: [nil, false, 0]).order(location_attribute_id: :desc).first

        now = Time.current
        user_id = User.current&.user_id

        if location_attribute
          location_attribute.update!(
            value_reference: level,
            changed_by: user_id,
            date_changed: now,
            voided: false
          )
        else
          LocationAttribute.create!(
            location_id: location.location_id,
            attribute_type_id: attribute_type_id,
            value_reference: level,
            uuid: SecureRandom.uuid,
            creator: user_id,
            date_created: now,
            voided: false
          )
        end

        render json: {
          location_id: location.location_id,
          facility_level: level,
          message: 'Facility level updated successfully'
        }, status: :ok
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
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

        # Map to objects with an ascending counter starting at 1 and include location_id
        formatted_districts = unique_names.each_with_index.map do |name, index|
          # Find a representative location for this district
          representative_location = Location.where(county_district: name).first
          {
            id: index + 1,
            name: name,
            location_id: representative_location&.location_id
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

      def authorized_for_location?(location_id)
        return false unless User.current
        return true if User.current.global_superuser?

        User.current.managed_location_ids.include?(location_id.to_i)
      end

      def normalize_facility_level(value)
        return nil if value.blank?

        ALLOWED_FACILITY_LEVELS.find { |allowed| allowed.casecmp(value.to_s.strip).zero? }
      end

      def facility_level_for_location(location_id)
        return nil if location_id.blank?

        explicit_level = location_attribute_value(location_id, FACILITY_LEVEL_ATTRIBUTE)
        return explicit_level if explicit_level.present?

        facility_type = location_attribute_value(location_id, FACILITY_TYPE_ATTRIBUTE)
        map_facility_type_to_level(facility_type)
      end

      def location_attribute_value(location_id, attribute_type_name)
        attribute_type_id = LocationAttributeType.where(name: attribute_type_name).pick(:location_attribute_type_id)
        return nil if attribute_type_id.blank?

        LocationAttribute.where(location_id:, attribute_type_id:)
                         .where(voided: [nil, false, 0])
                         .order(location_attribute_id: :desc)
                         .pick(:value_reference)
      end

      def map_facility_type_to_level(facility_type)
        case facility_type.to_s.strip.downcase
        when 'health centre', 'health center'
          'Primary'
        when 'district hospital'
          'Secondary'
        when 'central hospital'
          'Tertiary'
        end
      end
    end
  end
end
