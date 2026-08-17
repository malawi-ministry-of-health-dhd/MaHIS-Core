# frozen_string_literal: true

module Api
  module V1
    module Pharmacy
      class BatchesController < ApplicationController
        #  GET /pharmacy/batches
        def index
          render json: paginate(service.find_all_batches(filter_params))
        end

        # GET /pharmacy/batches/:batch_number
        def show
          render json: service.find_batch_by_batch_number(params[:id], filter_params)
        end


        # POST /pharmacy/batches
        #
        # Request structure:
        #
        #   {
        #     batch_number: string,
        #     program_id: integer (optional, defaults to current user's program),
        #     location_id: string (optional, defaults to current user's location),
        #     items: [
        #       {
        #          drug_id: *int,
        #          pack_size: int,
        #          quantity: *double,
        #          expiry_date: *string, # Date in 'YYYY-MM-DD'
        #          delivery_date: string, # Same as above (defaults to today)
        #          barcode: string
        #       }
        #     ]
        #   }
        #


        def create
          batch_params = params['_json']
          program_id = params[:program_id] || User.current&.program&.program_id
          location_id = params[:location_id] || User.current.location_id
          
          batch_params.each do |param|
            param['program_id'] = program_id
            param['location_id'] = location_id
          end
          
          render json: service.create_batches(batch_params), status: :created
        end
        

        def update
          params[:batch_number] = params[:id]
          create
        end

        # DELETE /pharmacy/batches/:batch_number
        def destroy
          service.void_batch(params[:id], params.require(:reason), filter_params)

          render status: :no_content
        end

        private

        def filter_params
          {
            program_id: params[:program_id] || User.current&.program&.program_id,
            location_id: params[:location_id] || User.current.location_id
          }
        end

        def service
          StockManagementService.new
        end
      end
    end
  end
end
