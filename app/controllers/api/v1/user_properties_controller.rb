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
    end
  end
end
