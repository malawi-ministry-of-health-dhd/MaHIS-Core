# frozen_string_literal: true

module Api
  module V1
    class GlobalPropertiesController < ApplicationController
      def search
        name, = params.require %i[property]
        location_id = User.current.location_id

        render json: GlobalProperty.where('property like ? AND location_id = ?', "%#{name}%", location_id)
      end

      def show
        name = params.require %i[property]
        skip_location_filter = ActiveModel::Type::Boolean.new.cast(params[:skip_location_filter])
        
        query = { property: name }

        unless skip_location_filter
          query[:location_id] = User.current.location_id
        end

        property = GlobalProperty.find_by(query)

        if property
          render json: { property.property => property.property_value }
        else
          render json: { errors: ["Property not found"] }, status: :not_found
        end
      end

      def create(success_response_status: :created)
        name, value = params.require %i[property property_value]
        location_id = User.current.location_id

        property = GlobalProperty.find_or_initialize_by(property: name, location_id: location_id)
        property.property_value = value

        if property.save
          render json: property, status: success_response_status
        else
          render json: { errors: property.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        create success_response_status: :ok
      end

      def destroy
        name = params.require %i[property]
        location_id = User.current.location_id
        
        property = GlobalProperty.find_by(property: name, location_id: location_id)
        if property.nil?
          render json: { errors: ["Property, #{name}, not found"] }, status: :not_found
        elsif property.destroy
          render status: :no_content
        else
          render json: { errors: property.errors }, status: :internal_server_error
        end
      end
    end
  end
end
