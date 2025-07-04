module Api
  module V1
    class PrinterConfigurationsController < ApplicationController
      # GET /api/v1/printer_configurations
      def index
        @printer_configurations = PrinterConfiguration.all
        render json: @printer_configurations
      end

      # GET /api/v1/printer_configurations/:id
      def show
        @printer_configuration = PrinterConfiguration.find(params[:id])
        render json: @printer_configuration
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Printer configuration not found' }, status: :not_found
      end

      # POST /api/v1/printer_configurations
      def create
        @printer_configuration = PrinterConfiguration.new(printer_configurations_params)

        if @printer_configuration.save
          render json: @printer_configuration, status: :created
        else
          render json: { errors: @printer_configuration.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/printer_configurations/:id
      def update
        @printer_configuration = PrinterConfiguration.find(params[:id])

        if @printer_configuration.update(printer_configurations_params)
          render json: @printer_configuration
        else
          render json: { errors: @printer_configuration.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Printer configuration not found' }, status: :not_found
      end

      # DELETE /api/v1/printer_configurations/:id
      def destroy
        @printer_configuration = PrinterConfiguration.find(params[:id])
        @printer_configuration.destroy
        head :no_content # Responds with a 204 No Content status
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Printer configuration not found' }, status: :not_found
      end

      private

      def printer_configurations_params
        params.require(:printer_configuration).permit(:ip_address, :location_id, :printer_name)
      end
    end
  end
end