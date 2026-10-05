class DataVerificationService
    def encounters_done_per_provider(params)
      start_date, end_date, program_id = verify_params(params)

      query = ActiveRecord::Base.connection.select_all <<~SQL
        SELECT
        CONCAT(p.given_name, ' ', p.family_name) AS username, 
        u.user_id,
        u.person_id,
        et.name
        FROM encounter e
        INNER JOIN encounter_type et ON et.encounter_type_id = e.encounter_type
          AND e.program_id = #{program_id}
          AND e.voided = 0
        INNER JOIN users u on u.user_id = e.creator
        INNER JOIN person_name p ON p.person_id = u.person_id
          AND u.retired = 0
        WHERE DATE(e.encounter_datetime) BETWEEN #{start_date} AND #{end_date}
      SQL

      report = {}

      query.each do |en|
        username = en['username']
        encounter_type = en['name']
        report[username] ||= {}
        report[username][encounter_type] ||= 0
        report[username][encounter_type] += 1
      end

      report
    end

    # user_property keeps one row per (user_id, property) - overwritten on
    # every change, not a history - so this can only ever report a user's
    # latest password change, never a running count of how many times
    # they've changed it. It used to read the `last_password_reset` key,
    # which nothing writes any more; password changes now write
    # LoginResponseService::PASSWORD_UPDATED_PROPERTY instead (see
    # UserService.touch_password_updated!), as an iso8601 timestamp rather
    # than a plain date, so the range check is done in Ruby rather than a
    # SQL date cast.
    def password_changes(params)
      verify_params(params)
      range = Date.parse(params[:start_date])..Date.parse(params[:end_date])

      query = ActiveRecord::Base.connection.select_all <<~SQL
        SELECT up.property_value, u.user_id, CONCAT(p.given_name, ' ', p.family_name) AS username
        FROM user_property up
        INNER JOIN users u ON u.user_id = up.user_id
        INNER JOIN person_name p ON p.person_id = u.person_id
        WHERE up.property = '#{LoginResponseService::PASSWORD_UPDATED_PROPERTY}'
      SQL

      report = {}

      query.each do |pr|
        date = begin
          Time.zone.parse(pr['property_value']).to_date
        rescue ArgumentError, TypeError
          nil
        end
        next unless date && range.cover?(date)

        username = pr['username']
        report[username] ||= []
        report[username].push({
          date: pr['property_value'],
          user_id: pr['user_id']
        })
      end

      report
    end

    def encounters_done_odd_hours(params)
      start_date, end_date, program_id = verify_params(params)

      query = ActiveRecord::Base.connection.select_all <<~SQL
        SELECT e.encounter_id, 
          e.patient_id, e.encounter_datetime, 
          TIME_FORMAT(encounter_datetime, '%k') AS time,
          CONCAT(p.given_name, ' ', p.family_name) AS username, 
          u.user_id
          FROM encounter e
          INNER JOIN users u ON u.user_id = e.creator
          INNER JOIN person_name p ON p.person_id = u.person_id
          WHERE e.encounter_datetime BETWEEN #{start_date} AND #{end_date}
          AND e.patient_id IN (
            SELECT patient_id
            FROM patient_program
            WHERE program_id = #{program_id}
          )
          AND TIME_FORMAT(encounter_datetime, '%k') > 17
          AND TIME_FORMAT(encounter_datetime, '%k') < 6
          GROUP BY e.encounter_id
          ORDER BY encounter_datetime ASC
      SQL

      report = {}

      query.each do |en|
        user_id = en['user_id']
        time = en['time']
        patient_id = en['patient_id']
        username = en['username']
        date = en['encounter_datetime']
        encounter_id = en['encounter_id']

        report[username] ||= []

        report[username].push({
          time:,
          patient_id:,
          date:,
          username:,
          user_id:,
          encounter_id:
        })
      end

      report
    end
    
    private_methods 
    
    def verify_params(params)
      start_date = params[:start_date]
      end_date = params[:end_date]
      program_id = params[:program_id]

      if start_date.blank? || end_date.blank? || program_id.blank?
        raise InvalidParameterError, 'start_date, end_date and program_id are required'
      end

      start_date = ActiveRecord::Base.connection.quote(start_date)
      end_date = ActiveRecord::Base.connection.quote(end_date)

      [start_date, end_date, program_id]
    end
  
end
