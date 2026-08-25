# frozen_string_literal: true

require 'utils/remappable_hash'
require 'zebra_printer/init'
require 'securerandom'

module Api
  module V1
    class LocationsController < ApplicationController
      # Raised for an unrecognised ward_sex, so create and update can both turn
      # it into a 422 rather than a 500.
      class InvalidWardSexError < StandardError; end

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

      # GET   /locations/:id/departments
      # PUT   /locations/:id/departments
      # PATCH /locations/:id/departments
      #
      # :id is the FACILITY, not the department: departments are global, so the
      # only thing that varies per site is whether each one is switched on there.
      # GET lists every department with its status for that facility; PUT/PATCH
      # takes { department_id, enabled } and flips one.
      def departments
        facility = Location.find_by(location_id: params[:id])
        return render json: { error: 'Location not found' }, status: :not_found unless facility

        if request.get?
          disabled = disabled_department_ids(facility.location_id)
          return render json: department_locations.map { |department|
            {
              location_id: department.location_id,
              name: department.name,
              enabled: disabled.exclude?(department.location_id.to_s)
            }
          }
        end

        unless authorized_for_location?(facility.location_id)
          return render json: { error: 'Location is out of your authorized scope' }, status: :forbidden
        end

        department = department_locations.find_by(location_id: params[:department_id])
        return render json: { error: 'Department not found' }, status: :not_found unless department

        enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
        return render json: { error: 'enabled is required' }, status: :unprocessable_entity if enabled.nil?

        set_department_enabled(facility.location_id, department.location_id, enabled)

        render json: {
          location_id: facility.location_id,
          department_id: department.location_id,
          name: department.name,
          enabled: enabled,
          message: "Department #{enabled ? 'enabled' : 'disabled'} for this facility"
        }, status: :ok
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end

      def create
        # Require and permit parameters
        params.require(:tag)
        params.require(:name)
        location_params = params.permit(:name, :description, :address1, :address2, :district,
                                        :parent_id, :tag, :city_village, :county_district, :department_id,
                                        :ward_sex)

        is_department = location_params[:tag].to_s.strip.casecmp('Department').zero?
        is_ward = location_params[:tag].to_s.strip.casecmp('Ward').zero?

        # Departments are global (site-agnostic): only a global superuser may
        # add them, and they carry no facility parent.
        if is_department && !User.current&.global_superuser?
          return render json: { error: 'Only a global superuser can add departments' }, status: :forbidden
        end

        # Every other location type (ward, section, ...) still hangs off a parent.
        params.require(:parent_id) unless is_department

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

        # Add parent location (global departments have none).
        unless is_department
          parent_location = Location.find_by(location_id: location_params[:parent_id])
          return render json: { error: 'Parent location not found' }, status: :bad_request unless parent_location

          location_attrs[:parent_location] = parent_location.location_id
        end

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

          # A ward belongs to a facility (its parent) and is classified by a
          # global department, stored as a location attribute. Whether it is a
          # male or female ward is recorded the same way.
          if is_ward
            assign_ward_department(location, location_params[:department_id])
            assign_ward_sex(location, location_params[:ward_sex])
          end

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
      rescue InvalidWardSexError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PUT   /locations/:id
      # PATCH /locations/:id
      #
      # Renames a facility unit and re-files it: a ward can move to a different
      # department, a section to a different ward. Only the fields that were sent
      # are touched, so a rename never disturbs the topology.
      def update
        location = Location.find_by(location_id: params[:id])
        return render json: { error: 'Location not found' }, status: :not_found unless location

        # Departments are global, so editing one edits it for every site --
        # gated the same way creating one is.
        if location_tagged?(location, 'Department')
          unless User.current&.global_superuser?
            return render json: { error: 'Only a global superuser can edit departments' }, status: :forbidden
          end
        else
          facility_id = owning_facility_id(location)
          unless facility_id.present? && authorized_for_location?(facility_id)
            return render json: { error: 'Location is out of your authorized scope' }, status: :forbidden
          end
        end

        update_params = params.permit(:name, :description, :parent_id, :department_id, :ward_sex)

        if update_params.key?(:name) && update_params[:name].to_s.strip.blank?
          return render json: { error: 'name cannot be blank' }, status: :unprocessable_entity
        end

        attrs = { changed_by: User.current&.user_id, date_changed: Time.now }
        attrs[:name] = update_params[:name].to_s.strip if update_params.key?(:name)
        attrs[:description] = update_params[:description] if update_params.key?(:description)

        if update_params[:parent_id].present?
          parent_location = Location.find_by(location_id: update_params[:parent_id])
          return render json: { error: 'Parent location not found' }, status: :bad_request unless parent_location

          attrs[:parent_location] = parent_location.location_id
        end

        location.update!(attrs)

        # A ward's department and its male/female marking are location
        # attributes, not columns, so they are set separately.
        if location_tagged?(location, 'Ward')
          repoint_ward_department(location, update_params[:department_id]) if update_params.key?(:department_id)
          assign_ward_sex(location, update_params[:ward_sex]) if update_params.key?(:ward_sex)
        end

        location.reload
        render json: location, include: {
          location_attributes: {
            only: %i[location_attribute_id attribute_type_id value_reference]
          }
        }
      rescue InvalidWardSexError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
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

      def location_tagged?(location, tag_name)
        tag_id = LocationTag.where('LOWER(TRIM(name)) = ?', tag_name.to_s.downcase).pick(:location_tag_id)
        return false if tag_id.blank?

        LocationTagMap.exists?(location_id: location.location_id, location_tag_id: tag_id)
      end

      # The facility a unit belongs to, so a ward and a section reach the same
      # authorization check: a ward's parent IS the facility, a section's parent
      # is a ward. Legacy wards parented to a department fall back to walking one
      # more level up.
      def owning_facility_id(location)
        return location.parent_location if location_tagged?(location, 'Ward')

        parent = Location.find_by(location_id: location.parent_location)
        return location.parent_location if parent.nil?

        parent.parent_location.presence || parent.location_id
      end

      # Points a ward at a different department. Reuses the existing marker so a
      # ward never ends up with two live department attributes.
      def repoint_ward_department(location, department_id)
        return if department_id.blank?

        attribute_type = find_or_create_department_attribute_type
        return unless attribute_type

        markers = LocationAttribute.where(
          location_id: location.location_id,
          attribute_type_id: attribute_type.location_attribute_type_id
        ).where(voided: [nil, false, 0]).order(location_attribute_id: :desc).to_a

        current = markers.shift
        now = Time.now
        user_id = User.current&.user_id

        # Anything beyond the newest marker is stale data from before this action
        # existed; voiding it here stops Location#department_id picking at random.
        markers.each do |stale|
          stale.update!(voided: true, voided_by: user_id, date_voided: now, void_reason: 'Superseded department attribute')
        end

        if current
          return if current.value_reference.to_s == department_id.to_s

          current.update!(value_reference: department_id.to_s, changed_by: user_id, date_changed: now)
        else
          assign_ward_department(location, department_id)
        end
      end

      # Every department, matching what GET /locations?tag=Department returns so
      # the admin screen and the rest of the app agree on the set.
      def department_locations
        tag = LocationTag.where('LOWER(TRIM(name)) = ?', 'department').first
        return Location.none unless tag

        Location.where(retired: false)
                .joins(:tag_maps)
                .merge(LocationTagMap.where(location_tag_id: tag.location_tag_id))
                .order(:name)
      end

      # The department location_ids this facility has switched off. Stored as
      # attributes on the facility rather than on the department, because a
      # department row is shared by every site.
      def disabled_department_ids(facility_id)
        attribute_type_id = LocationAttributeType
                            .where(name: Location::DISABLED_DEPARTMENT_ATTRIBUTE_TYPE_NAME)
                            .pick(:location_attribute_type_id)
        return [] if attribute_type_id.blank?

        LocationAttribute.where(location_id: facility_id, attribute_type_id: attribute_type_id)
                         .where(voided: [nil, false, 0])
                         .pluck(:value_reference)
                         .map(&:to_s)
      end

      # Enabling voids the facility's "disabled" marker; disabling adds one (or
      # revives the previous one, so repeated toggling does not grow the table).
      def set_department_enabled(facility_id, department_id, enabled)
        attribute_type = find_or_create_disabled_department_attribute_type
        return unless attribute_type

        markers = LocationAttribute.where(
          location_id: facility_id,
          attribute_type_id: attribute_type.location_attribute_type_id,
          value_reference: department_id.to_s
        )
        active = markers.where(voided: [nil, false, 0])
        now = Time.now
        user_id = User.current&.user_id

        if enabled
          active.each do |marker|
            marker.update!(voided: true, voided_by: user_id, date_voided: now,
                           void_reason: 'Department enabled for this facility')
          end
          return
        end

        return if active.exists?

        revivable = markers.order(location_attribute_id: :desc).first
        if revivable
          revivable.update!(voided: false, voided_by: nil, date_voided: nil, void_reason: nil,
                            changed_by: user_id, date_changed: now)
        else
          LocationAttribute.create!(
            location_id: facility_id,
            attribute_type_id: attribute_type.location_attribute_type_id,
            value_reference: department_id.to_s,
            uuid: SecureRandom.uuid,
            creator: user_id,
            date_created: now,
            voided: false
          )
        end
      end

      def find_or_create_disabled_department_attribute_type
        LocationAttributeType.find_or_create_by(name: Location::DISABLED_DEPARTMENT_ATTRIBUTE_TYPE_NAME) do |attribute_type|
          attribute_type.min_occurs = 0
          attribute_type.datatype = 'org.openmrs.customdatatype.datatype.FreeTextDatatype'
          attribute_type.description = 'A department this facility has switched off (value is the department location_id)'
          attribute_type.creator = User.current&.user_id
          attribute_type.date_created = Time.now
          attribute_type.retired = false
        end
      end

      # Persist which global department a ward belongs to as a location
      # attribute (value_reference = department location_id). No-op only when no
      # department was supplied; the attribute type is created on demand so this
      # does not depend on a separate seed run.
      def assign_ward_department(location, department_id)
        return if department_id.blank?

        attribute_type = find_or_create_department_attribute_type
        return unless attribute_type

        LocationAttribute.create(
          location_id: location.location_id,
          attribute_type_id: attribute_type.location_attribute_type_id,
          value_reference: department_id.to_s,
          uuid: SecureRandom.uuid,
          creator: User.current&.user_id,
          date_created: Time.now,
          voided: false
        )
      end

      # Marks a ward male or female. A blank value voids the marking, so a ward
      # can go back to having none. Reuses the single live attribute rather than
      # stacking rows, so Location#ward_sex never has to choose between two.
      def assign_ward_sex(location, value)
        ward_sex = Location.normalize_ward_sex(value)
        if value.present? && ward_sex.nil?
          raise InvalidWardSexError, "ward_sex must be one of: #{Location::WARD_SEXES.join(', ')}"
        end

        attribute_type = find_or_create_ward_sex_attribute_type
        return unless attribute_type

        now = Time.now
        user_id = User.current&.user_id
        live = LocationAttribute.where(
          location_id: location.location_id,
          attribute_type_id: attribute_type.location_attribute_type_id
        ).where(voided: [nil, false, 0]).order(location_attribute_id: :desc).to_a

        current = live.shift
        # Anything beyond the newest is stale; voiding it keeps the reader
        # deterministic.
        live.each do |stale|
          stale.update!(voided: true, voided_by: user_id, date_voided: now, void_reason: 'Superseded ward sex attribute')
        end

        if ward_sex.nil?
          current&.update!(voided: true, voided_by: user_id, date_voided: now, void_reason: 'Ward sex cleared')
          return
        end

        if current
          return if current.value_reference.to_s == ward_sex

          current.update!(value_reference: ward_sex, changed_by: user_id, date_changed: now)
        else
          LocationAttribute.create!(
            location_id: location.location_id,
            attribute_type_id: attribute_type.location_attribute_type_id,
            value_reference: ward_sex,
            uuid: SecureRandom.uuid,
            creator: user_id,
            date_created: now,
            voided: false
          )
        end
      end

      # Reuses the live type -- which on a seeded site is the one that came from
      # MaHIS-Metadata -- and only creates one where none exists yet. Explicitly
      # ignores retired rows so a superseded local copy is never picked up again.
      def find_or_create_ward_sex_attribute_type
        existing = LocationAttributeType
                   .where(name: Location::WARD_SEX_ATTRIBUTE_TYPE_NAME, retired: [nil, false, 0])
                   .order(:location_attribute_type_id)
                   .first
        return existing if existing

        LocationAttributeType.create!(
          name: Location::WARD_SEX_ATTRIBUTE_TYPE_NAME,
          min_occurs: 0,
          max_occurs: 1,
          datatype: 'org.openmrs.customdatatype.datatype.FreeTextDatatype',
          description: 'Whether a ward admits Male or Female patients',
          creator: User.current&.user_id,
          date_created: Time.now,
          retired: false
        )
      end

      def find_or_create_department_attribute_type
        LocationAttributeType.find_or_create_by(name: Location::DEPARTMENT_ATTRIBUTE_TYPE_NAME) do |attribute_type|
          attribute_type.min_occurs = 0
          attribute_type.max_occurs = 1
          attribute_type.datatype = 'org.openmrs.customdatatype.datatype.FreeTextDatatype'
          attribute_type.description = 'Global department a ward belongs to (value is the department location_id)'
          attribute_type.creator = User.current&.user_id
          attribute_type.date_created = Time.now
          attribute_type.retired = false
        end
      end

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
        location_tag = LocationTag.where('LOWER(name) = ?', tag.downcase).first ||
                       LocationTag.where('name like ?', "%#{tag}%").first
        return locations.none unless location_tag

        location_tag_id = location_tag.location_tag_id
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
