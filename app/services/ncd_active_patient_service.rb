class NcdActivePatientService
  def initialize(location_id)
    @location_id = location_id
  end

  def get_active_patients(filters = {})
    page = filters[:page]&.to_i || 1
    per_page = filters[:per_page]&.to_i || 10
    offset = (page - 1) * per_page

    # Get total count
    count_sql = build_count_query(filters)
    total_count = ActiveRecord::Base.connection.select_value(count_sql)

    # Get paginated results
    data_sql = build_data_query(filters, per_page, offset)
    raw_results = ActiveRecord::Base.connection.select_all(data_sql)

    # Format results
    formatted_results = format_patient_results(raw_results)

    {
      count: total_count,
      results: formatted_results
    }
  end

  private

  def build_count_query(filters)
    <<-SQL
      SELECT COUNT(DISTINCT p.patient_id)
      FROM (
        SELECT patient_id, location_id, encounter_datetime,
               ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY encounter_datetime DESC) as rn
        FROM encounter 
        WHERE voided = 0
      ) e
      INNER JOIN patient_program pp 
        ON e.patient_id = pp.patient_id 
        AND pp.program_id = 32 
        AND pp.voided = 0
      INNER JOIN patient p ON e.patient_id = p.patient_id
      INNER JOIN person pe ON p.patient_id = pe.person_id
      LEFT JOIN person_name pn ON pe.person_id = pn.person_id AND pn.voided = 0
      WHERE e.rn = 1 
        AND e.location_id = #{sanitize_number(@location_id)}
        #{build_filter_clauses(filters)}
    SQL
  end

  def build_data_query(filters, limit, offset)
    <<-SQL
      SELECT 
        p.patient_id,
        pe.person_id,
        pe.gender,
        pe.birthdate,
        pe.birthdate_estimated,
        pe.dead,
        pe.death_date,
        pe.creator,
        pe.date_created,
        pe.changed_by,
        pe.date_changed,
        pe.voided,
        pe.voided_by,
        pe.date_voided,
        pe.void_reason,
        pn.person_name_id,
        pn.given_name,
        pn.middle_name,
        pn.family_name,
        pn.family_name_suffix,
        pn.preferred,
        pa.person_address_id,
        pa.address1,
        pa.address2,
        pa.city_village,
        pa.state_province,
        pa.postal_code,
        pa.country,
        pa.latitude,
        pa.longitude,
        pi.patient_identifier_id,
        pi.identifier,
        pit.patient_identifier_type_id,
        pit.name as identifier_type_name,
        pattr.person_attribute_id,
        pattr.value as attribute_value,
        pattr.creator as attribute_creator,
        pattr.date_created as attribute_date_created,
        pattr.changed_by as attribute_changed_by,
        pattr.date_changed as attribute_date_changed,
        pattr.voided as attribute_voided,
        pattrtype.person_attribute_type_id,
        pattrtype.name as attribute_type_name,
        pattrtype.description as attribute_type_description,
        pattrtype.format as attribute_type_format,
        base.encounter_datetime,
        base.location_id
      FROM (
        SELECT 
          e.patient_id,
          e.location_id,
          e.encounter_datetime
        FROM (
          SELECT patient_id, location_id, encounter_datetime,
                 ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY encounter_datetime DESC) as rn
          FROM encounter 
          WHERE voided = 0
        ) e
        INNER JOIN patient_program pp 
          ON e.patient_id = pp.patient_id 
          AND pp.program_id = 32 
          AND pp.voided = 0
        INNER JOIN patient p ON e.patient_id = p.patient_id
        INNER JOIN person pe ON p.patient_id = pe.person_id
        LEFT JOIN person_name pn ON pe.person_id = pn.person_id AND pn.voided = 0
        WHERE e.rn = 1 
          AND e.location_id = #{sanitize_number(@location_id)}
          #{build_filter_clauses(filters)}
        ORDER BY e.encounter_datetime DESC
        LIMIT #{sanitize_number(limit)}
        OFFSET #{sanitize_number(offset)}
      ) base
      INNER JOIN patient p ON base.patient_id = p.patient_id
      INNER JOIN person pe ON p.patient_id = pe.person_id
      LEFT JOIN person_name pn ON pe.person_id = pn.person_id AND pn.voided = 0
      LEFT JOIN person_address pa ON pe.person_id = pa.person_id AND pa.voided = 0
      LEFT JOIN patient_identifier pi ON p.patient_id = pi.patient_id AND pi.voided = 0
      LEFT JOIN patient_identifier_type pit ON pi.identifier_type = pit.patient_identifier_type_id
      LEFT JOIN person_attribute pattr ON pe.person_id = pattr.person_id AND pattr.voided = 0
      LEFT JOIN person_attribute_type pattrtype ON pattr.person_attribute_type_id = pattrtype.person_attribute_type_id
      ORDER BY base.encounter_datetime DESC
    SQL
  end

  def build_filter_clauses(filters)
    clauses = []
    
    if filters[:given_name].present?
      clauses << "AND LOWER(pn.given_name) LIKE LOWER('%#{sanitize_string(filters[:given_name])}%')"
    end
    
    if filters[:family_name].present?
      clauses << "AND LOWER(pn.family_name) LIKE LOWER('%#{sanitize_string(filters[:family_name])}%')"
    end
    
    if filters[:middle_name].present?
      clauses << "AND LOWER(pn.middle_name) LIKE LOWER('%#{sanitize_string(filters[:middle_name])}%')"
    end
    
    if filters[:gender].present?
      clauses << "AND pe.gender = '#{sanitize_string(filters[:gender]).upcase}'"
    end
    
    if filters[:birthdate].present?
      clauses << "AND pe.birthdate = '#{sanitize_string(filters[:birthdate])}'"
    end
    
    clauses.join("\n        ")
  end

  def format_patient_results(raw_results)
    # Group by patient_id to handle multiple names, addresses, identifiers, and attributes
    grouped = raw_results.group_by { |row| row['patient_id'] }
    
    grouped.map do |patient_id, rows|
      first_row = rows.first
      
      {
        patient_id: patient_id.to_s,
        encounter_datetime: first_row['encounter_datetime'],
        location_id: first_row['location_id'].to_s,
        patient_identifiers: extract_identifiers(rows),
        person: {
          person_id: first_row['person_id'],
          gender: first_row['gender'],
          birthdate: first_row['birthdate']&.strftime('%Y-%m-%d'),
          birthdate_estimated: first_row['birthdate_estimated'],
          dead: first_row['dead'],
          death_date: first_row['death_date']&.strftime('%Y-%m-%d'),
          creator: first_row['creator'],
          date_created: first_row['date_created'],
          changed_by: first_row['changed_by'],
          date_changed: first_row['date_changed'],
          voided: first_row['voided'],
          voided_by: first_row['voided_by'],
          date_voided: first_row['date_voided'],
          void_reason: first_row['void_reason'],
          names: extract_names(rows),
          addresses: extract_addresses(rows),
          person_attributes: extract_attributes(rows)
        }
      }
    end
  end

  def extract_names(rows)
    rows.map do |row|
      next if row['person_name_id'].nil?
      
      {
        person_name_id: row['person_name_id'],
        given_name: row['given_name'],
        middle_name: row['middle_name'],
        family_name: row['family_name'],
        family_name_suffix: row['family_name_suffix'],
        preferred: row['preferred']
      }
    end.compact.uniq { |n| n[:person_name_id] }
  end

  def extract_addresses(rows)
    rows.map do |row|
      next if row['person_address_id'].nil?
      
      {
        person_address_id: row['person_address_id'],
        address1: row['address1'],
        address2: row['address2'],
        city_village: row['city_village'],
        state_province: row['state_province'],
        postal_code: row['postal_code'],
        country: row['country'],
        latitude: row['latitude'],
        longitude: row['longitude']
      }
    end.compact.uniq { |a| a[:person_address_id] }
  end

  def extract_identifiers(rows)
    rows.map do |row|
      next if row['patient_identifier_id'].nil?
      
      {
        patient_identifier_id: row['patient_identifier_id'],
        identifier: row['identifier'],
        type: {
          patient_identifier_type_id: row['patient_identifier_type_id'],
          name: row['identifier_type_name']
        }
      }
    end.compact.uniq { |i| i[:patient_identifier_id] }
  end

  def extract_attributes(rows)
    rows.map do |row|
      next if row['person_attribute_id'].nil?
      
      {
        person_attribute_id: row['person_attribute_id'],
        value: row['attribute_value'],
        creator: row['attribute_creator'],
        date_created: row['attribute_date_created'],
        changed_by: row['attribute_changed_by'],
        date_changed: row['attribute_date_changed'],
        voided: row['attribute_voided'],
        type: {
          person_attribute_type_id: row['person_attribute_type_id'],
          name: row['attribute_type_name'],
          description: row['attribute_type_description'],
          format: row['attribute_type_format']
        }
      }
    end.compact.uniq { |attr| attr[:person_attribute_id] }
  end

  def sanitize_string(value)
    ActiveRecord::Base.connection.quote_string(value.to_s)
  end

  def sanitize_number(value)
    value.to_i
  end
end