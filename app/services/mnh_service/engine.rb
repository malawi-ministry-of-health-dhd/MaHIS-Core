# frozen_string_literal: true

module MnhService
  class Engine
    LOGGER = Rails.logger

    def stats(program_id, date = nil, location_id: nil)
      program = Program.find(program_id)
      name = program.name.to_s.upcase.strip

      if anc_program?(name)
        anc_stats(program_id, date, location_id: location_id)
      elsif labour_program?(name)
        labour_stats(program_id, date, location_id: location_id)
      elsif pnc_program?(name)
        pnc_stats(program_id, date, location_id: location_id)
      else
        raise ArgumentError, "Program #{program_id} is not ANC, Labour or PNC (name: #{program.name})"
      end
    end

    def anc_stats(program_id = nil, date = nil, location_id: nil)
      result = MnhService::AncStatsQueries.new(program_id, location_id: location_id).stats_hash(date)
      result[:date] = format_date(date) if date.present?
      result[:location_id] = resolved_location_id(location_id)
      LOGGER.info "[MnhService::Engine] anc_stats program_id=#{program_id} date=#{date} location_id=#{result[:location_id]}"
      result
    end

    def labour_stats(program_id = nil, date = nil, location_id: nil)
      result = MnhService::LabourStatsQueries.new(program_id, date, location_id: location_id).stats_hash
      result[:date] = format_date(date) if date.present?
      result[:location_id] = resolved_location_id(location_id)
      LOGGER.info "[MnhService::Engine] labour_stats program_id=#{program_id} date=#{date} location_id=#{result[:location_id]}"
      result
    end

    def pnc_stats(program_id = nil, date = nil, location_id: nil)
      result = MnhService::PncStatsQueries.new(program_id, date, location_id: location_id).stats_hash
      result[:date] = format_date(date) if date.present?
      result[:location_id] = resolved_location_id(location_id)
      LOGGER.info "[MnhService::Engine] pnc_stats program_id=#{program_id} date=#{date} location_id=#{result[:location_id]}"
      result
    end

    private

    def anc_program?(name)
      name == 'ANC PROGRAM'
    end

    def labour_program?(name)
      name == 'LABOUR PROGRAM' || name == 'LABOUR AND DELIVERY PROGRAM'
    end

    def pnc_program?(name)
      name == 'PNC PROGRAM' || name == 'POSTNATAL CARE PROGRAM'
    end

    def format_date(date)
      date.respond_to?(:to_date) ? date.to_date.iso8601 : date.to_s
    end

    def resolved_location_id(location_id)
      location_id.presence || Location.current&.location_id || User.current&.location_id
    end
  end
end
