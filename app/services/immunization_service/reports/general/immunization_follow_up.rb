# frozen_string_literal: true

module ImmunizationService
  module Reports
    module General
      class ImmunizationFollowUp
        def initialize(start_date:, end_date:)
            @start_date = Date.parse(start_date).beginning_of_day
            @end_date = Date.parse(end_date).end_of_day
        end

        def data
          raise StandardError, 'ImmunizationService::Reports::General::ImmunizationFollowUp is not implemented yet'
        end
      end
    end
  end
end
