# frozen_string_literal: true

##
# A collection of various helpers for dealing with global properties
class GlobalPropertyService
  ##
  # Instance method for CouchDB change listener
  # Sync a global property document from CouchDB to MySQL
  def create_or_update_from_couchdb(doc)
    unless valid_couchdb_document?(doc)
      Rails.logger.error("[Global Property Sync] Invalid CouchDB document: #{doc.inspect}")
      return
    end

    property_name = doc['property']
    property_value = doc['property_value']
    location_id = doc['location_id']
    description = doc['description']
    uuid = doc['uuid']

    begin
      # Find existing property by name and location, or create new one
      global_property = GlobalProperty.find_or_initialize_by(
        property: property_name,
        location_id: location_id
      )

      # Update attributes
      global_property.assign_attributes(
        property_value: property_value,
        description: description,
        uuid: uuid || SecureRandom.uuid
      )

      if global_property.save
        Rails.logger.info("[Global Property Sync] Successfully synced: #{property_name} (location: #{location_id})")
        'synced'
      else
        Rails.logger.error("[Global Property Sync] Failed to save: #{property_name}. Errors: #{global_property.errors.full_messages}")
        'failed'
      end
    rescue StandardError => e
      Rails.logger.error("[Global Property Sync] Error syncing #{property_name}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      'error'
    end
  end

  class << self
    def use_filing_numbers?
      GlobalProperty.where(property: 'use.filing.number', property_value: 'true')
                    .exists?
    end

    def site_code
      property = GlobalProperty.find_by(property: 'site_prefix', location_id: User.current.location_id)
      value = property&.property_value&.strip

      raise "Global property 'site_prefix' not set" unless value

      value
    end
  end

  private

  def valid_couchdb_document?(doc)
    doc.is_a?(Hash) &&
      doc['property'].present? &&
      doc['property_value'].present? &&
      doc['location_id'].present?
  end
end
