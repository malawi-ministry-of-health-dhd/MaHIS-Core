# frozen_string_literal: true

# rubocop:disable Style/ClassAndModuleChildren
# controller giving reports on drug movement
class Api::V1::Pharmacy::DrugMovementsController < ApplicationController
  # return an array of drug movement
  def show
    filters = allowed_params.merge(filter_context)
    items = ArtService::Pharmacy::DrugMovement.stock_movement(filters)

    render json: items, status: 200
  end

  private

  def filter_context
    {
      program_id: params[:program_id],
      location_id: params[:location_id] || User.current.location_id
    }
  end

  # these are the allowed params
  def allowed_params
    params.permit(%i[start_date end_date drug_id program_id location_id])
  end
end
# rubocop:enable Style/ClassAndModuleChildren
