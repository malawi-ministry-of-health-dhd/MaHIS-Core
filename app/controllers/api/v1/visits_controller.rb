module Api
    module V1
        class Api::V1::VisitsController < ApplicationController
            def check_patient_status
                patientId = params[:patient_id]
                visit = Visit.where(patientId: patientId, closedDateTime: nil)
                render json: visit, status: :ok
            end

            def create
                patientId = visit_params[:patientId] 
                identifier = visit_params[:identifier]

                if identifier.present?
                  patient_identifier = PatientIdentifier.where(identifier: identifier)
                  patientId = patient_identifier[0][:patient_id]
                end
             

                checkVisit = Visit.where(patientId: patientId, closedDateTime: nil).first
                if checkVisit.present?
                  render json: {
                    message: "There is an active visit for patient with ID #{patientId}",
                    visit: checkVisit
                  }, status: :ok
                  return
                end

                visit = Visit.new(visit_params.except(:identifier))
                visit.patientId = patientId
                if visit.save
                    render json: {message:"Visit created successfully", visit: visit}, status: :created
                else
                    render json: { errors: visit.errors.full_messages }, status: :unprocessable_entity
                end
            end


            def index
              patientId = params[:patientId] # Optional filter by patient ID
              status = params[:status] # Optional filter by status (active or closed)
              date = params[:date]
            
              # Fetch all visits, optionally filtering by patientId or status
              visits = Visit.select('visits.*, patient_identifier.identifier AS identifier')
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
            
              # Return the list of visits as JSON
              render json: visits, status: :ok
            end   
            


            #def close   
                       
            #    visitId = params[:id]
            #    visit = Visit.find_by(id: visitId);

            #    if visit.nil?
            #        render json: { errors: "visit with id #{visitId} doesn't exist" }, status: :unprocessable_entity
            #        return
            #    end
            #    visit.update(closedDateTime: params[:visit][:closedDateTime]);

            #    activeStage = Stage.find_by(patient_id:visit.patientId, status: true)

            #    if activeStage
            #        begin
            #          activeStage.update!(status: false)
            #        rescue ActiveRecord::RecordInvalid => e
            #          Rails.logger.debug("Failed to update status: #{e.message}")
            #        end
            #    end 
            #end
            def close
                visit_id = params[:id]
                visit = Visit.find_by(id: visit_id)
              
                unless visit
                  render json: { errors: "Visit with id #{visit_id} doesn't exist" }, status: :unprocessable_entity
                  return
                end

                existing_stage = Stage.find_by(
                  patient_id: visit.patientId,
                  location_id: User.current.location_id
                )
                existing_stage.destroy if existing_stage

                closed_datetime = params.dig(:visit, :closedDateTime)
                visit.update(closedDateTime: closed_datetime)
              
                active_stage = Stage.find_by(patient_id: visit.patientId, status: true)

              
                if active_stage
                  begin
                    active_stage.update!(status: false)
                  rescue ActiveRecord::RecordInvalid => e
                    Rails.logger.debug("Failed to update stage status: #{e.message}")
                  end
                end
              end
              

            private
            def visit_params
                params.require(:visit).permit(:patientId, :identifier, :startDate, :closedDateTime, :programId, :location_id)
            end

        end
    end   
end
