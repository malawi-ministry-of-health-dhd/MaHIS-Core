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
        filters = params.permit(%i[traditional_authority_id village_id name])

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

        render json: paginate(villages.order(:name))
      end

      def show
        village = Village.includes(:traditional_authority).find_by(village_id: params[:id])
        
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
        village.update!(
          name: params[:name] || village.name,
          parent_location: params[:ta_id] || village.parent_location,
          creator: User.current.id,
          date_created: Time.current
        )
        render json: village.reload
      rescue StandardError => e
        render json: { error: e.message }, status: :bad_request
      end
    end
  end
end
