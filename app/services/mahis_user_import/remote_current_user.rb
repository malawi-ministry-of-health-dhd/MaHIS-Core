# frozen_string_literal: true

module MahisUserImport
  class RemoteCurrentUser
    SUPERUSER_ROLE_NAMES = ['Superuser', 'Global Superuser', 'District Superuser', 'Facility Superuser'].freeze

    attr_reader :user_id, :location_id, :role_names, :managed_location_ids

    def initialize(user:, locations:)
      @user_id = user['user_id'] || user[:user_id]
      @location_id = user['location_id'] || user[:location_id]
      @role_names = Array(user['roles'] || user[:roles]).map { |role| role['role'] || role[:role] }.compact
      @managed_location_ids = resolve_managed_location_ids(locations)
    end

    def global_superuser?
      role_names.include?('Global Superuser')
    end

    def district_superuser?
      role_names.include?('District Superuser')
    end

    def is_superuser?
      (role_names & SUPERUSER_ROLE_NAMES).any?
    end

    private

    def resolve_managed_location_ids(locations)
      return nil if global_superuser?

      ids = [location_id.to_i]
      if district_superuser?
        ids += locations.select { |location| location.parent_location.to_i == location_id.to_i }
                        .map { |location| location.location_id.to_i }
      end
      ids.compact.uniq
    end
  end
end
