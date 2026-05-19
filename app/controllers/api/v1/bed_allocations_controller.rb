# frozen_string_literal: true

module Api
  module V1
    class BedAllocationsController < ApplicationController
      before_action :set_allocation, only: %i[show release transfer discharge]

      def index
        allocations = filtered_allocations
        render json: paginate(allocations).map { |allocation| serialize_allocation(allocation) }
      end

      def show
        render json: serialize_allocation(@allocation)
      end

      def create
        allocation = service.allocate_bed(allocation_params, User.current)
        render json: serialize_allocation(allocation), status: :created
      rescue NotFoundError, InvalidParameterError => e
        render_service_error(e)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def release
        allocation = service.release_bed(@allocation, params.require(:release_reason), User.current)
        render json: serialize_allocation(allocation)
      rescue ActionController::ParameterMissing => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      rescue InvalidParameterError => e
        render_service_error(e)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def transfer
        allocation = service.transfer_patient(@allocation, params.require(:new_bed_id), User.current, params[:reason])
        render json: serialize_allocation(allocation), status: :created
      rescue ActionController::ParameterMissing => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      rescue NotFoundError, InvalidParameterError => e
        render_service_error(e)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def discharge
        allocation = service.discharge_patient_from_bed(@allocation, User.current, params.require(:reason))
        render json: serialize_allocation(allocation)
      rescue ActionController::ParameterMissing => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      rescue InvalidParameterError => e
        render_service_error(e)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      private

      def filtered_allocations
        allocations = BedAllocation.unscoped.includes(:bed, patient: :person)
        allocations = allocations.for_bed(params[:bed_id]) if params[:bed_id].present?
        allocations = allocations.for_patient(params[:patient_id]) if params[:patient_id].present?
        allocations = allocations.for_visit(params[:visit_id]) if params[:visit_id].present?
        allocations = allocations.where(allocation_status: params[:allocation_status]) if params[:allocation_status].present?
        allocations = allocations.active if ActiveModel::Type::Boolean.new.cast(params[:active_only])
        allocations = allocations.where('allocated_at >= ?', params[:from_date]) if params[:from_date].present?
        allocations = allocations.where('allocated_at <= ?', params[:to_date]) if params[:to_date].present?
        allocations.order(allocated_at: :desc, bed_allocation_id: :desc)
      end

      def set_allocation
        @allocation = BedAllocation.unscoped.find_by(bed_allocation_id: params[:id])
        return if @allocation

        render json: { errors: ['allocation_not_found'] }, status: :not_found
      end

      def allocation_params
        params.permit(:bed_id, :patient_id, :visit_id, :allocated_at, :allocation_reason, :notes)
      end

      def service
        @service ||= BedManagementService.new
      end

      def serialize_allocation(allocation)
        {
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
          bed: serialize_bed(allocation.bed),
          patient: serialize_patient(allocation.patient),
          voided: allocation.voided
        }
      end

      def serialize_bed(bed)
        return nil unless bed

        {
          bed_id: bed.bed_id,
          uuid: bed.uuid,
          bed_number: bed.bed_number,
          bed_label: bed.bed_label,
          location_id: bed.location_id,
          facility_id: bed.facility_id,
          bed_status: bed.bed_status,
          bed_type: bed.bed_type,
          retired: bed.retired
        }
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
        status = case error.message
                 when 'bed_not_found', 'patient_not_found', 'visit_not_found'
                   :not_found
                 when 'bed_already_occupied', 'patient_already_allocated'
                   :conflict
                 else
                   :unprocessable_entity
                 end

        render json: { errors: [error.message] }, status: status
      end

      def validation_status(record)
        record.errors.full_messages.any? { |message| message.include?('already has an active allocation') } ? :conflict : :unprocessable_entity
      end
    end
  end
end
