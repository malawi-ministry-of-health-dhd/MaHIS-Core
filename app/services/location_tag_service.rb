# frozen_string_literal: true

# Assigning location tags to an EXISTING location.
#
# A tag is not a label. For the administrative hierarchy it IS the record's
# identity: Village, District, TraditionalAuthority and Region each default_scope
# on their own tag, so stripping 'Village' from a village makes it vanish from
# every village list and dropdown while its `location` row and its user_villages
# assignments live on, unreachable. Nothing may hand those tags to a UI.
#
# ASSIGNABLE_TAG_NAMES is therefore a whitelist: the only tags this service will
# add or remove. Every other tag on a location is left exactly as it was, so a
# client cannot reach a structural tag even by asking for it. Widening the
# feature means adding a name here.
#
# The names are resolved against `location_tag` and never created. A name that
# is not in the table simply yields nothing to assign - deliberately the
# opposite of LocationsController#find_or_create_location_tag, where a typo
# mints a new phantom tag.
module LocationTagService
  ASSIGNABLE_TAG_NAMES = ['Village Clinic'].freeze

  # Raised when a caller asks for a tag outside the whitelist - a structural tag
  # included. Reported rather than silently ignored, so a mistaken client sees
  # the refusal instead of a no-op.
  class UnassignableTagError < StandardError; end

  class << self
    def assignable_tags
      LocationTag.where(name: ASSIGNABLE_TAG_NAMES).order(:name)
    end

    # What a location's tags look like to a client: every tag it currently
    # carries, each flagged with whether this service would let it be changed,
    # plus the assignable set with its current state for rendering toggles.
    def payload(location)
      assigned_ids = LocationTagMap.where(location_id: location.location_id).pluck(:location_tag_id)

      {
        location_id: location.location_id,
        name: location.name,
        tags: LocationTag.where(location_tag_id: assigned_ids).order(:name).map do |tag|
          {
            location_tag_id: tag.location_tag_id,
            name: tag.name,
            # false for the structural tags, which the client must render as
            # read-only rather than offer to remove.
            assignable: ASSIGNABLE_TAG_NAMES.include?(tag.name)
          }
        end,
        assignable_tags: assignable_tags.map do |tag|
          {
            location_tag_id: tag.location_tag_id,
            name: tag.name,
            description: tag.description,
            assigned: assigned_ids.include?(tag.location_tag_id)
          }
        end
      }
    end

    # Replaces the WHITELISTED tags on a location with the requested set. Tags
    # outside the whitelist are never touched, added or removed.
    def replace_assignable_tags!(location, tag_ids)
      # reject blanks before casting: a form-encoded empty array arrives as [""],
      # and "".to_i is 0, which would be reported as an unassignable tag id
      # instead of clearing the set.
      requested = Array(tag_ids).reject(&:blank?).map(&:to_i).uniq
      assignable = assignable_tags.index_by(&:location_tag_id)

      unassignable = requested - assignable.keys
      if unassignable.any?
        raise UnassignableTagError,
              "Tags cannot be assigned here: #{LocationTag.where(location_tag_id: unassignable).pluck(:name).presence || unassignable}"
      end

      ActiveRecord::Base.transaction do
        # Only ever the whitelist is in scope for removal, so a tag the client
        # never mentioned - Village, District - cannot be dropped by omission.
        (assignable.keys - requested).each do |tag_id|
          LocationTagMap.where(location_id: location.location_id, location_tag_id: tag_id).delete_all
        end

        requested.each do |tag_id|
          # The composite primary key already forbids duplicates; checking first
          # keeps a re-assign idempotent instead of raising RecordNotUnique.
          next if LocationTagMap.exists?(location_id: location.location_id, location_tag_id: tag_id)

          LocationTagMap.create!(location_id: location.location_id, location_tag_id: tag_id)
        end
      end

      payload(location)
    end
  end
end
