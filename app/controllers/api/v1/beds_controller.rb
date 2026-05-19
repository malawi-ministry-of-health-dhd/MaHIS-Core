# frozen_string_literal: true

module Api
  module V1
    class BedsController < ApplicationController
      before_action :set_bed, only: %i[show update destroy]

      def index
        beds = filtered_beds
        render json: paginate(beds).map { |bed| serialize_bed(bed) }
      end

      def show
        render json: serialize_bed(@bed)
      end

      def create
        bed = service.create_bed(bed_params, User.current)
        render json: serialize_bed(bed), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def update
        bed = service.update_bed(@bed, bed_params, User.current)
        render json: serialize_bed(bed)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def destroy
        bed = service.retire_bed(@bed, params.require(:retire_reason), User.current)
        render json: serialize_bed(bed)
      rescue ActionController::ParameterMissing => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      rescue InvalidParameterError => e
        render_service_error(e)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      private

      def filtered_beds
        beds = include_retired? ? Bed.unscoped : Bed.not_retired
        beds = beds.where(location_id: params[:location_id]) if params[:location_id].present?
        beds = beds.where(facility_id: params[:facility_id]) if params[:facility_id].present?
        beds = beds.where(bed_status: params[:bed_status]) if params[:bed_status].present?
        beds = beds.where(bed_type: params[:bed_type]) if params[:bed_type].present?
        beds = apply_occupancy_filter(beds)
        beds.order(:location_id, :bed_number)
      end

      def apply_occupancy_filter(beds)
        case params[:occupancy_status].to_s.upcase
        when 'OCCUPIED'
          beds.where(bed_id: BedAllocation.active.select(:bed_id))
        when 'UNOCCUPIED'
          beds.where.not(bed_id: BedAllocation.active.select(:bed_id))
        else
          beds
        end
      end

      def include_retired?
        ActiveModel::Type::Boolean.new.cast(params[:include_retired])
      end

      def set_bed
        @bed = Bed.unscoped.find_by(bed_id: params[:id])
        return if @bed

        render json: { errors: ['bed_not_found'] }, status: :not_found
      end

      def bed_params
        params.permit(:bed_number, :bed_label, :location_id, :facility_id, :bed_status, :bed_type, :description)
      end

      def service
        @service ||= BedManagementService.new
      end

      def serialize_bed(bed)
        allocation = bed.current_allocation
        {
          bed_id: bed.bed_id,
          uuid: bed.uuid,
          bed_number: bed.bed_number,
          bed_label: bed.bed_label,
          location_id: bed.location_id,
          facility_id: bed.facility_id,
          bed_status: bed.bed_status,
          bed_type: bed.bed_type,
          description: bed.description,
          occupancy_status: allocation.present? ? 'OCCUPIED' : 'UNOCCUPIED',
          current_allocation: allocation ? serialize_allocation(allocation, include_bed: false) : nil,
          current_patient: allocation ? serialize_patient(allocation.patient) : nil,
          retired: bed.retired
        }
      end

      def serialize_allocation(allocation, include_bed: true)
        data = {
          bed_allocation_id: allocation.bed_allocation_id,
          uuid: allocation.uuid,
          bed_id: allocation.bed_id,
          patient_id: allocation.patient_id,
          visit_id: allocation.visit_id,
          allocated_at: allocation.allocated_at,
          released_at: allocation.released_at,
          allocation_status: allocation.allocation_status,
          allocation_reason: allocation.allocation_reason,
          release_reason: allocation.release_reason,
          notes: allocation.notes,
          voided: allocation.voided
        }
        data[:bed] = serialize_bed(allocation.bed) if include_bed && allocation.bed
        data
      end

      def serialize_patient(patient)
        return nil unless patient

        {
          patient_id: patient.patient_id,
          name: patient.name,
          gender: patient.gender,
          identifier: patient.patient_identifiers.order(date_created: :desc).first&.identifier
        }
      end

      def render_validation_error(record)
        render json: { errors: record.errors.full_messages }, status: validation_status(record)
      end

      def render_service_error(error)
        status = %w[bed_already_occupied patient_already_allocated].include?(error.message) ? :conflict : :unprocessable_entity
        render json: { errors: [error.message] }, status: status
      end

      def validation_status(record)
        record.errors.full_messages.any? { |message| message.include?('already has an active allocation') } ? :conflict : :unprocessable_entity
      end
    end
  end
end
