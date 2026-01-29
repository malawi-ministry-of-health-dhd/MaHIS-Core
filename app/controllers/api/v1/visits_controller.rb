module Api
    module V1
        class Api::V1::VisitsController < ApplicationController
            include CouchdbSync
            def check_patient_status
                patientId = params[:patient_id]
                visit = Visit.where(patientId: patientId, closedDateTime: nil)
                render json: visit, status: :ok
            end

            def create
              data = VisitService.new.create_visit(visit_params)
              create_couchdb_visit(data)
              render json: data
            end

            def create_couchdb_visit(doc_data)
              doc_id = generate_document_id(doc_data)
              sync_to_couchdb(doc_data, "visits", doc_id)
            end
            def generate_document_id(visit)
              # Create composite _id from identifier and start_date
              identifier = visit[:identifier] || 'unknown'
              start_date = visit["startDate"] ? visit["startDate"].to_time.strftime("%Y-%m-%dT%H:%M:%S") : 'no-date'
              "#{identifier}_#{start_date}"
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
              render json: VisitService.new.close_visit(visit_params)
            end

            def generate_visit_number

              # close off hanging visits for screening screen
              VisitService.daily_visits(category: 'screening')

              taken_visit_ids = Observation.joins(encounter: :visit).where(
                visit: { date_stopped: nil },
                obs: { concept_id: ConceptName.find_by_name('AETC Visit number').concept_id }
              ).select('obs.value_numeric')&.map(&:value_numeric)

              visit_number = 1

              visit_number += 1 while taken_visit_ids.include?(visit_number) && not_assigned_today?(visit_number)

              render json: { next_visit_number: visit_number }, status: :ok
            end
              

            private
            def visit_params
                params.permit(:patientId, :identifier, :startDate,:fullName, :closedDateTime, :programId, :location_id)
            end

        end
    end   
end
