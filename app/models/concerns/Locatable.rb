# rubocop:disable Naming/FileName
# frozen_string_literal: true

# rubocop:disable Style/Documentation

# this class is responsible for assigning a
# site id to a record on save

# when a table has a site id attached to it,
# make sure its assigned during save
# the site_id is collected from the logged in user who belongs to a location

module Locatable
  extend ActiveSupport::Concern

  included do
    # Check if table exists and has location_id column before setting up associations
    # This prevents errors during schema loading when tables don't exist yet

    if ActiveRecord::Base.connection.table_exists?(table_name) && location_id_column?

      belongs_to :location, foreign_key: :location_id, primary_key: :location_id, optional: true

      default_scope do
        location = current_location_id
        if location.present?
          where(location_id: location)
        else
          all
        end
      end
      validates :location_id, presence: true
      before_save :set_location_id

    end
  rescue ActiveRecord::NoDatabaseError, Mysql2::Error
    # Database doesn't exist yet, skip setup
  end

  def set_location_id
    # Skip if location_id is already set
    return if location_id.present?

    # Try to inherit location from related records first
    self.location_id = resolve_location_from_relationships

    # Fall back to current location if no relationship provides it
    self.location_id ||= current_location_id
  end

  # Resolve location_id from related records (encounter, order, etc.)
  def resolve_location_from_relationships
    # If record belongs to an encounter, use encounter's location
    # Use unscoped to bypass default_scope location filtering
    if respond_to?(:encounter_id) && encounter_id.present?
      return Encounter.unscoped.find_by(encounter_id: encounter_id)&.location_id
    end

    # If record belongs to an order, use order's encounter location
    if respond_to?(:order_id) && order_id.present?
      order = Order.unscoped.find_by(order_id: order_id)
      if order
        encounter = Encounter.unscoped.find_by(encounter_id: order.encounter_id)
        return encounter&.location_id
      end
    end

    # If record has a parent observation (obs_group_id), use parent's location
    if respond_to?(:obs_group_id) && obs_group_id.present?
      parent = Observation.unscoped.find_by(obs_id: obs_group_id)
      return parent&.location_id if parent
    end

    nil
  end

  class_methods do
    def location_id_column?
      column_names.include?('location_id')
    end

    def current_location_id
      # Prioritize Location.current (thread-local) over User.current.location
      # This allows explicit location context to take precedence
      Location.current&.id || User.current&.location&.id
    end
  end
end

# rubocop:enable Style/Documentation, Naming/FileName
