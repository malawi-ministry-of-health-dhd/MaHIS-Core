# frozen_string_literal: true

module Api
  module V1
    class VillagesController < ApplicationController
      def create
        params.require(%i[name traditional_authority_id])

        ActiveRecord::Base.transaction do
          village = Village.create!(
            name: params[:name],
            parent_location: params[:traditional_authority_id],
            creator: User.current.id,
            date_created: Time.now
          )

          LocationTagMap.create!(
            location_id: village.location_id,
            location_tag_id: LocationTag.find_by(name: 'Village').id
          )

          render json: village, status: :created
        end
      rescue StandardError => e
        render json: { error: e.message }, status: :bad_request
      end

      def index
        filters = params.permit(:traditional_authority_id, :village_id, :name, :page, :page_size, village: {})

        traditional_authority_id, name, village_id = filters.values_at(:traditional_authority_id, :name, :village_id)
        villages = Village.all

        if traditional_authority_id
          villages = villages.where(parent_location: traditional_authority_id)
        end

        if name
          villages = villages.where('name like ?', "%#{name}%")
        end

        if village_id
          villages = villages.where(location_id: village_id)
        end

        total_count = villages.count
        page = (params[:page] || 1).to_i
        page_size = (params[:page_size] || DEFAULT_PAGE_SIZE).to_i
        paginated_data = paginate(villages.order(:name))

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

      def show
        village = Village.includes(:traditional_authority).find_by(location_id: params[:id])

        if village
          render json: village.as_json(include: :traditional_authority)
        else
          render json: { error: 'Village not found' }, status: :not_found
        end
      end
      def destroy
        reason = params[:retired_reason] || "Retired by administrator"
        village = Village.find(params[:id])
        village.void(reason)
      
        render json: { message: "Village successfully retired" }, status: :ok
      rescue StandardError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
      def update
        village = Village.find(params[:id])

        village.update!(update_params)

        render json: village.reload
      rescue StandardError => e
        render json: { error: e.message }, status: :bad_request
      end

      private

      def update_params
        permitted = params.permit(:name, :ta_id, :traditional_authority_id, village: %i[name ta_id traditional_authority_id])
        village_params = permitted.fetch(:village, ActionController::Parameters.new)

        {}.tap do |attrs|
          attrs[:name] = village_params[:name] || permitted[:name] if village_params[:name].present? || permitted[:name].present?

          parent_location = village_params[:traditional_authority_id] || village_params[:ta_id] ||
                            permitted[:traditional_authority_id] || permitted[:ta_id]
          attrs[:parent_location] = parent_location if parent_location.present?
        end
      end
    end
  end
end
