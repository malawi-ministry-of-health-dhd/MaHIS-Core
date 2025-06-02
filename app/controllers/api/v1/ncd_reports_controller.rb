module Api
  module V1
    class NcdReportsController < ApplicationController
      def ncd_active_patients
        filters = params.permit(%i[given_name middle_name family_name birthdate gender per_page page sync_to_mongo])
        @current_date = Date.current
        @location_id = User.current.location_id

        base_patients = Patient.joins(encounters: [:program, :type])
                              .where(program: { program_id: 32 })
                              .where(encounters: { location_id: @location_id })
                              .where(encounter_type: { name: ['PATIENT REGISTRATION', 'REGISTRATION'] })
                              .distinct

        if filters[:given_name].present? || filters[:family_name].present? || filters[:gender].present?
          filtered_patients = service.find_patients_by_name_and_gender(
            filters[:given_name], 
            filters[:middle_name], 
            filters[:family_name], 
            filters[:gender]
          )
          base_patients = base_patients.merge(filtered_patients)
        end

        base_patients = base_patients.joins(:person).where(person: { birthdate: filters[:birthdate] }) if filters[:birthdate].present?

        
        
        sync_patients_to_mongo(base_patients)
        

        total_records = base_patients.count
        results = paginate(base_patients)

        render json: {
          count: total_records,
          results: results
        }, status: :ok
      end

      # Method to sync patients to MongoDB
      def sync_patients_to_mongo(patients)
        puts "Syncing #{patients.count} patients to MongoDB..."
        
        patients.includes(:encounters, :person).find_each do |patient|
          begin
            latest_encounter = patient.encounters
                                .joins(:program)
                                .where(program: { program_id: 32 })
                                .where(location_id: @location_id)
                                .order(encounter_datetime: :desc)
                                .first
            
            # Add validation to ensure latest_encounter exists
            if latest_encounter.nil?
              Rails.logger.error "No encounters found for patient #{patient.patient_id}"
              next
            end

            patient_data = patient.as_json
            ncd_patient = NcdActivePatient.find_or_initialize_by(patient_id: patient.patient_id)

            ncd_patient.encounter_datetime = latest_encounter.encounter_datetime
            ncd_patient.location_id = @location_id.to_s
            ncd_patient.active_patient = patient_data
            ncd_patient.last_synced_at = Time.current
            
            unless ncd_patient.save
              Rails.logger.error "Failed to save patient #{patient.patient_id}: #{ncd_patient.errors.full_messages}"
            end
          rescue => e
            Rails.logger.error "Error syncing patient #{patient.patient_id}: #{e.message}\n#{e.backtrace.join("\n")}"
            raise e # Re-raise the error to see it in development
          end
        end
      end

      def ncd_active_patients_from_mongo
        filters = params.permit(%i[given_name middle_name family_name birthdate gender per_page page identifier])
        @location_id = User.current.location_id

        # Build MongoDB query based on the actual document structure
        mongo_query = { location_id: @location_id.to_s }

        # Add name filters - names are nested in active_patient.person.names array
        if filters[:given_name].present?
          mongo_query["active_patient.person.names.given_name"] = /#{Regexp.escape(filters[:given_name])}/i
        end

        if filters[:middle_name].present?
          mongo_query["active_patient.person.names.middle_name"] = /#{Regexp.escape(filters[:middle_name])}/i
        end

        if filters[:family_name].present?
          mongo_query["active_patient.person.names.family_name"] = /#{Regexp.escape(filters[:family_name])}/i
        end

        # Gender filter
        if filters[:gender].present?
          mongo_query["active_patient.person.gender"] = filters[:gender].upcase
        end

        # Birthdate filter
        if filters[:birthdate].present?
          begin
            birthdate = Date.parse(filters[:birthdate])
            mongo_query["active_patient.person.birthdate"] = birthdate.strftime("%Y-%m-%d")
          rescue ArgumentError
            # Invalid date format, skip filter
          end
        end

        # Identifier filter (search across all identifier types)
        if filters[:identifier].present?
          mongo_query["active_patient.patient_identifiers.identifier"] = /#{Regexp.escape(filters[:identifier])}/i
        end

        # Query MongoDB
        mongo_patients = NcdActivePatient.where(mongo_query)

        total_records = mongo_patients.count
        
        # Apply pagination
        page = filters[:page]&.to_i || 1
        per_page = filters[:per_page]&.to_i || 50
        
        results = mongo_patients.skip((page - 1) * per_page)
                              .limit(per_page)
                              .order_by(encounter_datetime: :desc)

        render json: {
          count: total_records,
          results: results.map(&:active_patient)
        }, status: :ok
      end

      private

      def service
        PatientService.new
      end
    end
  end
end