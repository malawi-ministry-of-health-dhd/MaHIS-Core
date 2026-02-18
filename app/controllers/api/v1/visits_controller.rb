module Api
    module V1
        class Api::V1::VisitsController < ApplicationController
            include CouchdbSync
            def check_patient_status
                patient_id = params[:patient_id]
                visit = Visit.where(patient_id: patient_id, date_stopped: nil)
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
              start_date = visit["date_started"] ? visit["date_started"].to_time.strftime("%Y-%m-%dT%H:%M:%S") : 'no-date'
              "#{identifier}_#{start_date}"
            end

          def index
            patient_id = params[:patient_id] 
            status = params[:status] 
            date = params[:date]
            identifier = params[:identifier]
            closed_date_time = params[:date_stopped]

            # Handle "null" string from frontend
            closed_date_time = nil if closed_date_time == "null"

            if identifier.present?
              patient_identifier = PatientIdentifier.find_by(identifier: identifier)
              patient_id = patient_identifier&.patient_id
            end

            # Build base query with joins
            visits = Visit.includes(:patient)
              .select('visit.*, patient_identifier.identifier AS identifier')
              .where(location_id: User.current.location_id)
              .joins('INNER JOIN patient ON patient.patient_id = visit.patient_id')
              .joins('INNER JOIN patient_identifier ON patient_identifier.patient_id = patient.patient_id AND patient_identifier.identifier_type = 3')

            # Apply filters
            visits = visits.where(patient_id: patient_id) if patient_id.present?

            # Filter by closed date - Fixed logic
            if closed_date_time.present?
              # If a specific date is provided, filter by that date
              visits = visits.where('DATE(date_stopped) = ?', closed_date_time)
            elsif params[:date_stopped] == "null"
              # If "null" is explicitly passed, get only open visits
              visits = visits.where(date_stopped: nil)
            end

            # Filter by start date if provided
            visits = visits.where('DATE(date_started) = ?', date) if date.present?
            
            # Map visit data
            visit_data = visits.map do |visit|
              visit.attributes.merge(
                identifier: visit.try(:identifier),
                full_name: visit.patient.try(:name)
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

              visit_number = next_daily_visit_number!

              render json: { next_visit_number: visit_number }, status: :ok
            end
              

            private
            def next_daily_visit_number!
              date_key = Time.zone.today.strftime('%Y-%m-%d')
              property_name = "aetc_visit_number_counter:#{date_key}"
              location_key = (User.current.location_id || 0).to_s

              GlobalProperty.transaction do
                counter = GlobalProperty.lock.find_or_create_by!(property: property_name, location_id: location_key) do |record|
                  record.property_value = '0'
                  record.description = 'Daily AETC visit number counter'
                  record.uuid = SecureRandom.uuid
                end

                next_number = counter.property_value.to_i + 1
                counter.update!(property_value: next_number.to_s)
                next_number
              end
            end

            def visit_params
                params.permit(:patient_id, :identifier, :date_started,:full_name, :date_stopped, :program_id, :location_id, :stage, :visit_type_id)
            end

        end
    end   
end
