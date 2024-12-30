# frozen_string_literal: true

module Api
  module V1
    class TraditionalAuthoritiesController < ApplicationController
      def create
        params = params.require(%i[name district_id])

        trad_auth = TraditionalAuthority.create(params)
        if trad_auth.errors.empty?
          render json: trad_auth, status: :created
        else
          render json: trad_auth.errors, status: :bad_request
        end
      end

      def index
        filters = params.permit(%i[district_id name traditional_authority_id])

        if filters.empty?
          render json: paginate(TraditionalAuthority.order(:name))
        else
          inexact_filters = make_inexact_filters(filters, [:name])
          render json: paginate(TraditionalAuthority.where(*inexact_filters).order(:name))
        end
      end

      def destroy
        trad_auth = TraditionalAuthority.find(params[:id])
        
        ActiveRecord::Base.transaction do
          trad_auth.villages.destroy_all
          trad_auth.destroy!
        end
      
        render json: { message: "Traditional Authority and associated villages successfully deleted" }, status: :ok
        rescue ActiveRecord::RecordNotDestroyed => e
          render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end
