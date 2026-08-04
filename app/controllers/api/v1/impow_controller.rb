# frozen_string_literal: true

module Api
  module V1
    class ImpowController < ApplicationController
      before_action :authenticate

      # GET /api/v1/impow/expected_patients
      # Get patients expected for clinic day based on appointment dates
      # Params:
      #   - program_id: required
      #   - date: optional (defaults to today)
      def expected_patients
        program_id = params.require(:program_id)
        date = params[:date]&.to_date || Date.today

        program = Program.find(program_id)
        appointment_engine = ImpowService::AppointmentEngine.new(
          program: program,
          patient: nil,
          retro_date: date
        )

        patients = appointment_engine.expected_patients_for_clinic_day(date)
        
        # Format the response to match frontend expectations
        formatted_patients = patients.map do |patient|
          {
            patientId: patient[:national_id],
            name: format_patient_name(patient[:given_name], patient[:family_name]),
            genderAge: format_gender_age(patient[:gender], patient[:birthdate], patient[:patient_id]),
            program: program.name,
            outcome: get_current_outcome(patient[:patient_id], program_id, date) || 'N/A',
            status: determine_patient_status(patient[:patient_id], date, program_id),
            patient_id: patient[:patient_id]
          }
        end

        render json: formatted_patients
      end

      private

      def get_current_outcome(patient_id, program_id, date)
        begin
          patient_program = PatientProgram.find_by(
            patient_id: patient_id,
            program_id: program_id
          )
          
          return nil unless patient_program
          
          # Get current state using the model's method
          current_state = patient_program.current_state(date)
          return nil unless current_state
          
          # Get the state name from program_workflow_state
          workflow_state = ProgramWorkflowState.find_by(program_workflow_state_id: current_state.state)
          workflow_state&.concept&.concept_names&.first&.name
        rescue StandardError => e
          Rails.logger.error("Error getting current outcome: #{e.message}")
          nil
        end
      end

      def format_patient_name(given_name, family_name)
        "#{given_name} #{family_name}".strip
      end

      def format_gender_age(gender, birthdate, patient_id)
        return "#{gender} / N/A" unless birthdate

        begin
          patient = Patient.find(patient_id)
          age_in_months = patient.age_in_months(Date.today)
          age_in_years = age_in_months / 12

          if age_in_years >= 2
            "#{gender} / #{age_in_years}y"
          else
            "#{gender} / #{age_in_months}m"
          end
        rescue StandardError => e
          Rails.logger.error("Error calculating age: #{e.message}")
          "#{gender} / N/A"
        end
      end

      def determine_patient_status(patient_id, date, program_id)
        # Check for encounters on the given date to determine status
        patient = Patient.find(patient_id)
        
        # Check if anthropometry is done
        anthropometry_done = encounter_exists?(patient, date, 'VITALS', program_id) ||
                             encounter_exists?(patient, date, 'ANTHROPOMETRY', program_id)
        
        # Check if medical assessment is done
        assessment_done = encounter_exists?(patient, date, 'CONSULTATION', program_id) ||
                          encounter_exists?(patient, date, 'MEDICAL ASSESSMENT', program_id)
        
        # Check if dispensation is done
        dispensation_done = encounter_exists?(patient, date, 'TREATMENT', program_id) ||
                            encounter_exists?(patient, date, 'DISPENSING', program_id)

        if dispensation_done && anthropometry_done
          'Complete'
        elsif assessment_done && anthropometry_done
          'Assessment Done'
        elsif anthropometry_done
          'Anthropometry Done'
        else
          'Pending'
        end
      rescue StandardError => e
        Rails.logger.error("Error determining patient status: #{e.message}")
        'Pending'
      end

      def encounter_exists?(patient, date, encounter_type_name, program_id)
        encounter_type = EncounterType.find_by_name(encounter_type_name)
        return false unless encounter_type

        Encounter.where(
          patient_id: patient.patient_id,
          encounter_type: encounter_type.encounter_type_id,
          program_id: program_id,
          voided: 0
        ).where(
          'DATE(encounter_datetime) = ?', date.strftime('%Y-%m-%d')
        ).exists?
      end
    end
  end
end
