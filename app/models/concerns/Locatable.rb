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
    begin
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
        # Must run before validation, not just before save: `validates
        # :location_id, presence: true` above runs before any before_save
        # callback, so a blank location_id (nil, or "" from an unset client
        # dropdown) would fail validation before this ever gets a chance to
        # fill in the fallback.
        before_validation :set_location_id

      end
    rescue ActiveRecord::NoDatabaseError, Mysql2::Error
      # Database doesn't exist yet, skip setup
    end
  end

  def set_location_id
    # `||=` only fills in nil — a blank string (e.g. an unset dropdown
    # serialized as "" by the client) is truthy in Ruby, so it silently
    # survived as an invalid location_id and failed the presence validation
    # below instead of falling back to the current location.
    self.location_id = self.class.current_location_id if location_id.blank?
  end

  class_methods do
    def location_id_column?
      column_names.include?('location_id')
    end

    def current_location_id
      Location.current&.id || User.current&.location&.id
    end
  end
end

# rubocop:enable Style/Documentation, Naming/FileName
