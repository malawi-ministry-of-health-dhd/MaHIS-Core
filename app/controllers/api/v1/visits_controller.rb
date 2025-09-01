module Api
    module V1
        class Api::V1::VisitsController < ApplicationController
            def check_patient_status
                patientId = params[:patient_id]
                visit = Visit.where(patientId: patientId, closedDateTime: nil)
                render json: visit, status: :ok
            end

            def create
              render json: VisitsService.new.create_visit(visit_params)
            end

            def index
              patientId = params[:patientId] # Optional filter by patient ID
              status = params[:status] # Optional filter by status (active or closed)
              date = params[:date]
              identifier = params[:identifier]

              if identifier.present?
                patient_identifier = PatientIdentifier.where(identifier: identifier)
                patientId = patient_identifier[0][:patient_id]
              end


              # Fetch all visits, optionally filtering by patientId or status
              visits = Visit.includes(:patient).select('visits.*, patient_identifier.identifier AS identifier')
                .where(location_id: User.current.location_id )
                .joins('INNER JOIN patient ON patient.patient_id = visits.patientId')
                .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = patient.patient_id AND patient_identifier.identifier_type = 3')
              visits = visits.group(:patientId)  if patientId.present?
            
              # Filter by patientId if provided
              #visits = visits.where(patientId: patientId) if patientId.present?
            
              # Filter by status (closed or active visits) if provided
              if status.present?
                case status.downcase
                when 'active'
                  visits = visits.where(closedDateTime: nil)
                when 'closed'
                  visits = visits.where.not(closedDateTime: nil)  
                end
              end

              #visits = visits.where('startDate = ?', Time.now)
              # today = Date.today
              visits = visits.where('DATE(startDate) = ?', date) if date.present?   
              visits = visits.where(patientId: patientId) if patientId.present?   

             visit_data = visits.map do |visit|
              visit.attributes.merge(
                identifier: visit.try(:identifier),
                fullName: visit.patient.try(:name)
              )
            end
           
              # Return the list of visits as JSON
              render json: visit_data, status: :ok
            end   
            
            def close
              render json: VisitsService.new.close_visit(visit_params)
            end
              

            private
            def visit_params
                params.permit(:patientId, :identifier, :startDate,:fullName, :closedDateTime, :programId, :location_id)
            end

        end
    end   
end
