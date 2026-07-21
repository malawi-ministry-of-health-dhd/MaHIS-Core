# frozen_string_literal: true

module Api
  module V1
    class UserPropertiesController < ApplicationController
      include ModelUtils

      def search
        name, = params.require %i[property]

        render json: UserProperty.where('property like ?', "%#{name}%")
      end

      def show
        name, = params.require %i[property]

        user = User.current.user_id
        user = params[:user_id] if params.include?(:user_id)

        property = UserProperty.find_by property: name,
                                        user_id: user
        render json: property
      end

      def unique_property
        name, value = params.require %i[property property_value]
        property = UserProperty.where(property: name, property_value: value).exists?
        render json: property
      end

      def create(success_response_status: :created)
        name, value = params.require %i[property property_value]

        provider = User.current.user_id
        provider = params[:user_id] if params.include?(:user_id)
        return unless validate_cross_user_property_update(provider)

        # MySQL INSERT ... ON DUPLICATE KEY UPDATE — atomic, race-safe
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO user_property (user_id, property, property_value)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE property_value = VALUES(property_value)",
            provider, name, value
          ])
        )

        property = UserProperty.find_by!(property: name, user_id: provider)
        render json: property, status: success_response_status
      rescue ActiveRecord::StatementInvalid => e
        render json: ["Failed to save property: #{e.message}"], status: :internal_server_error
      end

      def update
        create success_response_status: :ok
      end

      def destroy
        name = params.require %i[property]
        property = UserProperty.find_by name:, user_id: User.current.user_id
        if property.nil?
          render json: { errors: ["Property, #{name}, not found"] }
        elsif property.destroy
          render status: :no_content
        else
          render json: { errors: property.errors }, status: :internal_server_error
        end
      end

      private

      def validate_cross_user_property_update(provider)
        return true if provider.to_i == User.current.user_id.to_i

        target_user = manageable_user(provider)
        return true if can_manage_sensitive_user?(target_user)

        render json: {
          errors: ['You are not authorised to update properties for this user']
        }, status: :forbidden
        false
      rescue ActiveRecord::RecordNotFound
        render json: {
          errors: ["User #{provider} was not found or is outside your managed locations"]
        }, status: :not_found
        false
      end

      def manageable_user(user_id)
        users = User.includes(:roles)

        if User.current.global_superuser?
          users.unscope(where: :location_id).find(user_id)
        elsif User.current.district_superuser?
          users.unscope(where: :location_id).where(location_id: User.current.managed_location_ids).find(user_id)
        else
          users.find(user_id)
        end
      end

      def can_manage_sensitive_user?(target_user)
        current_rank = User.current&.superuser_rank || 0
        target_rank = target_user&.superuser_rank || 0

        # Equal rank is allowed so this matches the users_controller sensitive-update rule
        # (a superuser can manage same-rank peers). Self edits are already short-circuited above.
        current_rank == User::SUPERUSER_ROLE_RANK['global superuser'] || target_rank.zero? || current_rank >= target_rank
      end
    end
  end
end
