module Api
  module V1
    class AuditsController < ApplicationController
      DEFAULT_PER_PAGE = 200
      MAX_PER_PAGE     = 500

      def index
        @audits = Audit.includes(:user)

        filters.each do |k, v|
          @audits = @audits.where(k => v) if Audit.column_names.include?(k)
        end

        start_date, end_date, audit_action = filters[:start_date], filters[:end_date], filters[:audit_action]

        if start_date && end_date
          @audits = @audits.where(
            created_at: start_date.to_date.beginning_of_day..end_date.to_date.end_of_day
          )
        end

        @audits = @audits.where(action: audit_action) if audit_action

        @audits = @audits.order(created_at: :desc)

        total    = @audits.count
        per_page = [[params.fetch(:per_page, DEFAULT_PER_PAGE).to_i, 1].max, MAX_PER_PAGE].min
        page     = [params.fetch(:page, 1).to_i, 1].max

        @audits = @audits.limit(per_page).offset((page - 1) * per_page)

        render json: {
          data: @audits,
          meta: {
            total:    total,
            page:     page,
            per_page: per_page,
            pages:    (total.to_f / per_page).ceil
          }
        }
      end

      def dates
        audits = Audit.all
        audits = audits.where(user_id: params[:user_id]) if params[:user_id]
        render json: audits.distinct.pluck(Arel.sql("DATE(created_at)")).sort
      end

      private

      def filters
        params.permit %i[auditable_type audit_action user_id start_date end_date]
      end
    end
  end
end