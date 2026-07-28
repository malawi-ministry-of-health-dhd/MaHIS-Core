# frozen_string_literal: true

module DrugOrderService
  ORDER_PARAMS = %i[order_type_id concept_id orderer encounter_id start_date
                    auto_expire_date discontinued_date patient_id
                    accession_number obs_id program_id].freeze

  DRUG_ORDER_PARAMS = %i[drug_inventory_id].freeze

  FIND_FILTERS = ORDER_PARAMS + DRUG_ORDER_PARAMS

  DATETIME_FIELDS = %i[start_date auto_expire_date discontinued_date].freeze

  # The "awaiting dispensation" queue only looks this many days back (inclusive of
  # the requested date). Prescriptions older than the window are treated as stale
  # and dropped from the queue. This bounds the scan so the queue loads fast
  # instead of scanning every undispensed order ever recorded at the location.
  DISPENSATION_QUEUE_WINDOW_DAYS = 7
  FREQUENCY_DAILY_DOSES = {
    'OD' => 1,
    'BD' => 2,
    'TDS' => 3,
    'QID' => 4,
    'QDS' => 4,
    'NOCTE' => 1,
    'STAT' => 1,
    'WEEKLY' => 1
  }.freeze

  class << self
    def find(filters)
      date = filters.delete(:date)&.to_date
      program_id = filters.delete(:program_id)

      query = DrugOrder.joins(:order).where(*parse_search_filters(filters))

      if date || program_id
        encounter_query = Encounter.all

        encounter_query = encounter_query.where('encounter_datetime BETWEEN ? AND ?', date, date + 1.day) if date
        encounter_query = encounter_query.where(program_id:) if program_id

        query = query.merge(Order.joins(:encounter).merge(encounter_query))
      end

      query
    end

    def patients_awaiting_dispensation(filters = {})
      page = positive_integer(filters[:page], 1)
      per_page = positive_integer(filters[:per_page] || filters[:page_size], 1000)
      offset = (page - 1) * per_page
      cutoff = filters[:date]&.to_date || Date.current
      location_id = filters[:location_id].presence || User.current&.location_id
      search = filters[:search].to_s.strip
      search = '' if search.match?(/\A(undefined|null)\z/i)

      repair_missing_drug_order_rows(cutoff:, location_id:)

      pending_patients_sql = pending_dispensation_patients_sql(cutoff, location_id)
      pending_patient_rows_sql = pending_dispensation_patient_rows_sql(pending_patients_sql, search)

      rows = ActiveRecord::Base.connection.select_all(
        <<~SQL
          #{pending_patient_rows_sql}
          ORDER BY encounter_datetime DESC
          LIMIT #{per_page}
          OFFSET #{offset}
        SQL
      )

      # The awaiting-dispensation queue is small, so it almost always fits on a
      # single page. In that case derive the total from the page we already have
      # and skip the COUNT query, which would otherwise re-run the full (costly)
      # pending-patients aggregation a second time.
      count =
        if page == 1 && rows.length < per_page
          rows.length
        else
          ActiveRecord::Base.connection.select_value(
            "SELECT COUNT(*) FROM (#{pending_patient_rows_sql}) pending_patients"
          ).to_i
        end

      {
        count:,
        page:,
        per_page:,
        results: rows.map { |row| format_pending_dispensation_patient(row) }
      }
    end

    def fetch_all_patient_drug_orders(patient_id, repair_missing: true)
      repair_missing_drug_order_rows(patient_id:) if repair_missing

      # Quote patient ID for SQL safety
      quoted_patient_id = ActiveRecord::Base.connection.quote(patient_id)

      # An order is dispensed once it has a non-voided AMOUNT DISPENSED obs with
      # a positive numeric value - the same rule the online awaiting-dispensation queue uses
      # (see pending_dispensation_patients_sql). Stamping the flag here lets the
      # offline record know a synced order was already dispensed online, so the
      # offline has_pending_dispensation flag matches the online queue. When the
      # concept is missing nothing counts as dispensed, matching the online query.
      dispensed_concept_ids = dispensation_concept_ids
      dispensed_ids_sql = dispensed_concept_ids.any? ? dispensed_concept_ids.join(',') : 'NULL'

      # Query to fetch all drug orders for the patient
      medication = ActiveRecord::Base.connection.select_all <<-SQL
        SELECT
          d.name AS drug_name,
          t.quantity AS quantity,
          o.start_date AS start_date,
          o.auto_expire_date AS expire_date,
          o.instructions AS instructions,
          o.order_id AS order_id,
          t.drug_inventory_id AS drug_id,
          e.encounter_id AS encounter_id,
          e.encounter_datetime AS encounter_date,
          e.location_id AS location_id,
          t.frequency AS frequency,
          t.prn AS prn,
          t.dose AS dose,
          t.units AS units,
          t.equivalent_daily_dose AS equivalent_daily_dose,
          e.program_id AS program_id,
          EXISTS (
            SELECT 1
            FROM obs dispensation_obs
            WHERE dispensation_obs.order_id = o.order_id
              AND dispensation_obs.voided = 0
              AND dispensation_obs.concept_id IN (#{dispensed_ids_sql})
              AND dispensation_obs.value_numeric > 0
          ) AS dispensed
        FROM orders o
        INNER JOIN drug_order t ON o.order_id = t.order_id
        INNER JOIN drug d ON d.drug_id = t.drug_inventory_id
        INNER JOIN encounter e ON e.encounter_id = o.encounter_id
        WHERE o.voided = 0
          AND o.patient_id = #{quoted_patient_id}
        ORDER BY e.program_id ASC, e.encounter_datetime DESC;
      SQL

      # Transform the result into an array of drug orders with all fields
      medication.map do |m|
        {
          drug_name: m['drug_name'],
          quantity: m['quantity'],
          start_date: m['start_date'],
          expire_date: m['expire_date'],
          instructions: m['instructions'],
          order_id: m['order_id'],
          drug_id: m['drug_id'],
          encounter_id: m['encounter_id'],
          encounter_date: m['encounter_date'],
          location_id: m['location_id'],
          frequency: m['frequency'],
          prn: m['prn'],
          dose: m['dose'],
          units: m['units'],
          equivalent_daily_dose: m['equivalent_daily_dose'],
          program_id: m['program_id'],
          dispensed: m['dispensed'].to_i == 1
        }
      end
    rescue StandardError => e
      # Log the error and return an empty array
      Rails.logger.error("Error fetching drug orders for patient #{patient_id}: #{e.message}")
      []
    end

    # Creates drug orders in bulk.
    #
    # Returns [drug_order, false] if successful else [null, true]
    #
    # Parameters:
    #   - encounter: Is the encounter to attach the drug_orders to
    #   - plain_orders: An array of create_params (see below).
    #
    #  create_params:
    #    {
    #       drug_inventory_id: ...,
    #       start_date: ...,
    #       auto_expire_date: ...,
    #       obs_id: ...,
    #       instructions: ...,
    #       dose: ...,
    #       frequency: ...,
    #       prn: ...,
    #       units: ...,   // Can be omitted
    #       equivalent_daily_dose: ...,
    #       quantity: ... // Can be omitted
    #    }
    def create_drug_orders(encounter:, drug_orders:)
      ActiveRecord::Base.transaction do
        order_type = OrderType.find_by_name('Drug Order')

        saved_drug_orders = []

        drug_orders.each_with_index do |drug_order, i|
          order = create_order(encounter:, create_params: drug_order,
                               order_type:)

          raise_model_error(order, "Unable to create order #{i}") unless order.errors.empty?

          drug_order = create_drug_order order:, create_params: drug_order
          raise_model_error(drug_order, "Unable to create drug order #{i}") unless drug_order.errors.empty?

          saved_drug_orders << drug_order
        end

        saved_drug_orders
      end
    end

    def update_drug_orders(quantity_updates)
      # TODO: Update more than just quantity
      ActiveRecord::Base.transaction do
        orders = quantity_updates.collect do |update|
          order = DrugOrder.find(update[:order_id])
          order.quantity = update[:quantity].to_i
          order.save! # Any errors here aren't of our doing...
          order
        end

        return orders, false
      end
    end

    def repair_missing_drug_order_rows(patient_id: nil, cutoff: nil, location_id: nil)
      repaired = 0

      orphan_drug_orders_scope(patient_id:, cutoff:, location_id:).find_each do |order|
        next if DrugOrder.exists?(order_id: order.order_id)

        drug = matching_drug_for_order(order)
        next unless drug

        DrugOrder.create!(drug_order_attributes_for(order, drug))
        repaired += 1
      rescue ActiveRecord::RecordNotUnique
        next
      end

      repaired
    end

    private

    def orphan_drug_orders_scope(patient_id:, cutoff:, location_id:)
      scope = Order
        .joins(:encounter)
        .joins('LEFT JOIN drug_order missing_drug_order ON missing_drug_order.order_id = orders.order_id')
        .where('orders.voided = 0')
        .where('encounter.voided = 0')
        .where('missing_drug_order.order_id IS NULL')
        .where(
          'EXISTS (
            SELECT 1
            FROM drug orphan_drug
            WHERE orphan_drug.concept_id = orders.concept_id
              AND orphan_drug.retired = 0
          )'
        )

      scope = scope.where('orders.patient_id = ?', patient_id) if patient_id.present?
      scope = scope.where('encounter.location_id = ?', location_id) if location_id.present?

      if cutoff.present?
        window_start = TimeUtils.day_bounds(cutoff - (DISPENSATION_QUEUE_WINDOW_DAYS - 1).days)[0]
        window_end = TimeUtils.day_bounds(cutoff)[1]
        scope = scope.where(
          '((orders.start_date >= ? AND orders.start_date <= ?)
            OR (orders.start_date IS NULL AND encounter.encounter_datetime >= ? AND encounter.encounter_datetime <= ?))',
          window_start,
          window_end,
          window_start,
          window_end
        )
      end

      scope
    end

    def matching_drug_for_order(order)
      drugs = Drug.where(concept_id: order.concept_id).order(:drug_id).to_a
      return if drugs.empty?

      instruction_drug_name = order.instructions.to_s.split(':', 2).first
      normalized_instruction_name = normalize_drug_name(instruction_drug_name)
      drugs.find { |drug| normalize_drug_name(drug.name) == normalized_instruction_name } || drugs.first
    end

    def normalize_drug_name(name)
      name.to_s.downcase.gsub(/\s+/, ' ').strip
    end

    def drug_order_attributes_for(order, drug)
      parsed_instructions = parse_drug_order_instructions(order.instructions)

      {
        order_id: order.order_id,
        drug_inventory_id: drug.drug_id,
        dose: parsed_instructions[:dose],
        frequency: parsed_instructions[:frequency],
        prn: 0,
        units: parsed_instructions[:units].presence || drug.units,
        equivalent_daily_dose: parsed_instructions[:equivalent_daily_dose] || 1,
        quantity: dispensed_quantity_for_order(order.order_id)
      }
    end

    def parse_drug_order_instructions(instructions)
      body = instructions.to_s.split(':', 2).last.to_s
      match = body.match(
        /\A\s*(?<dose>\d+(?:\.\d+)?)\s*(?<units>.*?)\s+(?<frequency>OD|BD|TDS|QID|QDS|NOCTE|STAT|WEEKLY)\b/i
      )
      return {} unless match

      dose = match[:dose].to_f
      frequency = match[:frequency].upcase
      multiplier = FREQUENCY_DAILY_DOSES[frequency]

      {
        dose:,
        units: match[:units].to_s.strip.presence,
        frequency:,
        equivalent_daily_dose: multiplier ? dose * multiplier : nil
      }
    end

    def dispensed_quantity_for_order(order_id)
      concept_ids = dispensation_concept_ids
      return 0 if concept_ids.empty?

      Observation
        .where(order_id:, voided: 0, concept_id: concept_ids)
        .where('value_numeric > 0')
        .sum(:value_numeric)
        .to_i
    end

    def pending_dispensation_patient_rows_sql(pending_patients_sql, search)
      search_clause, search_binds = pending_dispensation_patient_search_clause(search)

      sanitize_sql_array([
        <<~SQL,
          SELECT
            pending.patient_id,
            pending.encounter_datetime,
            pending.location_id,
            pending.program_ids,
            pending.program_names,
            pe.gender,
            pn.given_name,
            pn.family_name
          FROM (#{pending_patients_sql}) pending
          INNER JOIN patient p ON p.patient_id = pending.patient_id
          INNER JOIN person pe ON pe.person_id = p.patient_id AND pe.voided = 0
          LEFT JOIN person_name pn
            ON pn.person_id = pe.person_id
           AND pn.voided = 0
           AND pn.person_name_id = (
             SELECT pn2.person_name_id
             FROM person_name pn2
             WHERE pn2.person_id = pe.person_id
               AND pn2.voided = 0
             ORDER BY pn2.date_created DESC, pn2.person_name_id DESC
             LIMIT 1
           )
          WHERE 1 = 1
            #{search_clause}
        SQL
        *search_binds
      ])
    end

    def pending_dispensation_patient_search_clause(search)
      return ['', []] if search.blank?

      escaped_search = ActiveRecord::Base.sanitize_sql_like(search.downcase)
      name_like = "%#{escaped_search}%"
      identifier_like = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"

      [
        <<~SQL.squish,
          AND (
            LOWER(CONCAT(COALESCE(pn.given_name, ''), ' ', COALESCE(pn.family_name, ''))) LIKE ?
            OR CAST(pending.patient_id AS CHAR) LIKE ?
            OR EXISTS (
              SELECT 1
              FROM patient_identifier pi
              WHERE pi.patient_id = pending.patient_id
                AND pi.voided = 0
                AND LOWER(pi.identifier) LIKE ?
            )
          )
        SQL
        [name_like, identifier_like, identifier_like.downcase]
      ]
    end

    def dispensation_concept_ids
      @dispensation_concept_ids ||= ConceptName
                                    .where(voided: 0, name: 'Amount dispensed')
                                    .distinct
                                    .pluck(:concept_id)
    end

    def pending_dispensation_patients_sql(cutoff, location_id)
      window_start = TimeUtils.day_bounds(cutoff - (DISPENSATION_QUEUE_WINDOW_DAYS - 1).days)[0]
      window_end = TimeUtils.day_bounds(cutoff)[1]
      queue_datetime = 'COALESCE(o.start_date, e.encounter_datetime)'

      where_clauses = [
        'o.voided = 0',
        'e.voided = 0',
        'COALESCE(drdo.quantity, 0) <= 0',
        '((o.start_date >= ? AND o.start_date <= ?) OR (o.start_date IS NULL AND e.encounter_datetime >= ? AND e.encounter_datetime <= ?))'
      ]
      binds = [window_start, window_end, window_start, window_end]

      # An order is dispensed once it has a non-voided AMOUNT DISPENSED obs with
      # a positive numeric value. Zero-quantity observations can exist for failed
      # or out-of-stock attempts and should leave the order in the queue.
      dispensed_concept_ids = dispensation_concept_ids
      if dispensed_concept_ids.any?
        where_clauses << <<~SQL.squish
          NOT EXISTS (
            SELECT 1
            FROM obs dispensation_obs
            WHERE dispensation_obs.order_id = o.order_id
              AND dispensation_obs.voided = 0
              AND dispensation_obs.concept_id IN (?)
              AND dispensation_obs.value_numeric > 0
          )
        SQL
        binds << dispensed_concept_ids
      end

      if location_id.present?
        where_clauses << 'e.location_id = ?'
        binds << location_id
      end

      sanitize_sql_array([
        <<~SQL,
          SELECT
            o.patient_id,
            MAX(#{queue_datetime}) AS encounter_datetime,
            MAX(e.location_id) AS location_id,
            GROUP_CONCAT(DISTINCT e.program_id ORDER BY e.program_id SEPARATOR ',') AS program_ids,
            GROUP_CONCAT(DISTINCT prg.name ORDER BY prg.name SEPARATOR ', ') AS program_names
          FROM drug_order drdo
          INNER JOIN orders o ON o.order_id = drdo.order_id
          INNER JOIN encounter e ON e.encounter_id = o.encounter_id
          LEFT JOIN program prg ON prg.program_id = e.program_id
          WHERE #{where_clauses.join(' AND ')}
          GROUP BY o.patient_id
        SQL
        *binds
      ])
    end

    def format_pending_dispensation_patient(row)
      program_names = row['program_names'].to_s.split(', ').reject(&:blank?)

      {
        patient_id: row['patient_id'].to_s,
        given_name: row['given_name'],
        family_name: row['family_name'],
        full_name: [row['given_name'], row['family_name']].compact.join(' ').strip,
        gender: row['gender'],
        encounter_datetime: row['encounter_datetime'],
        location_id: row['location_id']&.to_s,
        program_ids: row['program_ids'].to_s.split(',').reject(&:blank?).map(&:to_i),
        program_names:,
        source_label: program_names.presence&.join(', ') || 'Medication orders'
      }
    end

    def positive_integer(value, fallback)
      integer = value.to_i
      integer.positive? ? integer : fallback
    end

    def sanitize_sql_array(values)
      ActiveRecord::Base.send(:sanitize_sql_array, values)
    end

    def parse_search_filters(filters)
      query_cond = []
      query_params = []

      filters.each do |k, v|
        k = k.to_sym
        if ORDER_PARAMS.include?(k)
          if DATETIME_FIELDS.include?(k)
            query_cond << "`orders`.`#{k}` BETWEEN ? AND ?"
            query_params.concat(TimeUtils.day_bounds(v.to_date))
          else
            query_cond << "`orders`.`#{k}` = ?"
            query_params << v
          end
        elsif DRUG_ORDER_PARAMS.include?(k)
          query_cond << "`drug_order`.`#{k}` = ?"
          query_params << v
        else
          raise InvalidParameterError, "Invalid parameter for drug order: #{k}"
        end
      end

      [query_cond.join(' AND ')] + query_params
    end

    def create_order(encounter:, create_params:, order_type:)
      start_date = TimeUtils.retro_timestamp(create_params[:start_date].to_date)
      drug_runout_date = TimeUtils.retro_timestamp(create_params[:auto_expire_date].to_date)

      order = Order.create(
        order_type_id: order_type.order_type_id,
        concept_id: Drug.find(create_params[:drug_inventory_id]).concept_id,
        encounter_id: encounter.encounter_id,
        patient_id: encounter.patient_id,
        orderer: User.current.user_id,
        start_date:,
        auto_expire_date: drug_runout_date,
        obs_id: create_params[:obs_id],
        instructions: create_params[:instructions]
      )

      # Store user specified drug run out date separately as it is overriden
      # based on the drugs that actually get dispensed.

      # Determine which concept to use and any additional attributes based 
      # on the encounter type and presence of batch number
      if create_params[:batch_number].present?
        concept_id = ConceptName.find_by_name!('Batch Number').concept_id
        value_text = create_params[:batch_number]
        comments = 'Batch Number for drug ordered'
      else
        concept_id = ConceptName.find_by_name('Drug end date').concept_id
        value_text = nil
        comments = 'User specified drug run out date during drug prescription'
      end

      # Create the observation based on the determined logic
      Observation.create!(
        concept_id: concept_id,
        encounter:,
        person_id: encounter.patient_id,
        order:, 
        obs_datetime: start_date,
        value_datetime: drug_runout_date,
        value_text: value_text,
        comments: comments,
        location_id: User.current.location_id
      )

      order
    end

    def create_drug_order(order:, create_params:)
      drug = Drug.find(create_params[:drug_inventory_id])

      DrugOrder.create(
        drug_inventory_id: drug.drug_id,
        order_id: order.id,
        dose: create_params[:dose],
        frequency: create_params[:frequency],
        prn: create_params[:prn] || 0,
        units: create_params[:units] || drug.units,
        equivalent_daily_dose: create_params[:equivalent_daily_dose],
        quantity: create_params[:quantity] || 0
      )
    end

    def drug_quantity(_drug, create_params)
      auto_expire_date = Date.strptime(create_params[:auto_expire_date])
      start_date = Date.strptime(create_params[:start_date])
      duration = auto_expire_date - start_date
      duration.to_i * create_params[:equivalent_daily_dose].to_i
    end

    def raise_model_error(model, prefix)
      errors = model.errors.map { |k, v| "#{k}: #{v}" }.join(', ')
      raise InvalidParameterError, "#{prefix}: #{errors}"
    end
  end
end
