# frozen_string_literal: true

module Api
  module V1
    class TraditionalAuthoritiesController < ApplicationController
      def create
        params.require(%i[name district_id])
        
        ActiveRecord::Base.transaction do
          ta = TraditionalAuthority.create!(
            name: params[:name],
            parent_location: params[:district_id],
            creator: User.current.id,
            date_created: Time.current
          )

          LocationTagMap.create!(
            location_id: ta.location_id,
            location_tag_id: LocationTag.find_by(name: 'Traditional Authority').id
          )

          render json: ta, status: :created
        end
      rescue StandardError => e
        render json: { error: e.message }, status: :bad_request
      end

      def index
        filters = params.permit(%i[district_id name traditional_authority_id])

        district_id, name, traditional_authority_id = filters.values_at(:district_id, :name, :traditional_authority_id)
        traditional_authorities = TraditionalAuthority.all

        if district_id
          traditional_authorities = traditional_authorities.where(parent_location: district_id)
        end

        if name
          traditional_authorities = traditional_authorities.where('name like ?', "%#{name}%")
        end

        if traditional_authority_id
          traditional_authorities = traditional_authorities.where(location_id: traditional_authority_id)
        end

        # Get total count before pagination
        total_count = traditional_authorities.count

        # Apply pagination
        paginated_data = paginate(traditional_authorities.order(:name))

        # Get pagination parameters
        page = (params[:page] || 1).to_i
        page_size = (params[:page_size] || 10).to_i

        render json: {
          data: paginated_data,
          pagination: {
            current_page: page,
            per_page: page_size,
            total_count: total_count,
            total_pages: (total_count / page_size.to_f).ceil
          }
        }
      end

      def destroy
        reason = params[:retired_reason] || "Retired by administrator"
        ta = TraditionalAuthority.find(params[:id])

        ActiveRecord::Base.transaction do
          # Retire all associated villages first
          ta.villages.each { |village| village.void(reason) }
          # Retire the TA itself
          ta.void(reason)
        end

        render json: { message: "Traditional Authority and associated villages successfully retired" }, status: :ok
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
      def update
        ta = TraditionalAuthority.find(params[:id])

        ta.update!(
          name: params[:name] || ta.name,
          parent_location: params[:district_id] || ta.parent_location,
        )

        render json: ta.reload
      rescue StandardError => e
        render json: { error: e.message }, status: :bad_request
      end
    end
  end
end
