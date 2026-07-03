# frozen_string_literal: true

require 'ostruct'

module ImpowService
  class ReportEngine
    attr_reader :program

    LOGGER = Rails.logger

    REPORTS = {
      'APPOINTMENTS' => ImpowService::Reports::AppointmentsReport
    }.freeze

    def generate_report(type:, **kwargs)
      call_report_manager(:build_report, type:, **kwargs)
    end

    def find_report(type:, **kwargs)
      call_report_manager(:find_report, type:, **kwargs)
    end

    def missed_appointments(start_date, end_date, **kwargs)
      REPORTS['APPOINTMENTS'].new(start_date: start_date.to_date,
                                  end_date: end_date.to_date, **kwargs).missed_appointments
    end

    private

    def call_report_manager(method, type:, **kwargs)
      start_date = kwargs.delete(:start_date)
      end_date = kwargs.delete(:end_date)
      name = kwargs.delete(:name)
      type = report_type(type)

      report_manager = REPORTS[type.name.upcase].new(
        type:, name:, start_date:, end_date:, **kwargs
      )

      report_manager.send(method)
    end

    def report_type(name)
      type = ReportType.find_by_name(name)
      return type if type

      return OpenStruct.new(name: name.upcase) if REPORTS[name.upcase]

      raise NotFoundError, "Report, #{name}, not found"
    end
  end
end
