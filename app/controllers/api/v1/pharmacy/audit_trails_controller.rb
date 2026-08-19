# frozen_string_literal: true

module Api
  module V1
    module Pharmacy
      class AuditTrailsController < ApplicationController
        def show
          filters = params.permit(%i[transaction_date drug_id batch_number transaction_reason program_id location_id])
          filters = filters.merge(filter_context)

          trail = drilled_audit_trail transaction_date: filters[:transaction_date],
                                      drug_id: filters[:drug_id],
                                      batch_number: filters[:batch_number],
                                      transaction_reason: filters[:transaction_reason],
                                      program_id: filters[:program_id],
                                      location_id: filters[:location_id]

          render json: trail, status: :ok
        end

        def stock_report
          render json: service.stock_report(filter_context), status: :ok
        end

        def show_grouped_audit_trail
          filters = params.permit(%i[start_date end_date transaction_date drug_id batch_number program_id location_id])
          filters = filters.merge(filter_context)

          trail = grouped_audit_trail from: filters[:start_date],
                                      to: filters[:end_date],
                                      transaction_date: filters[:transaction_date],
                                      drug_id: filters[:drug_id],
                                      batch_number: filters[:batch_number],
                                      program_id: filters[:program_id],
                                      location_id: filters[:location_id]

          render json: trail, status: :ok
        end

        private

        def filter_context
          {
            program_id: params[:program_id],
            location_id: params[:location_id] || User.current.location_id
          }
        end

        def drilled_audit_trail(**kwargs)
          service.retrieve_drilled_transactions(**kwargs)
        end

        def grouped_audit_trail(**kwargs)
          service.retrieve_grouped_transactions(**kwargs)
        end

        def service
          ArtService::Pharmacy::AuditTrail
        end
      end
    end
  end
end
