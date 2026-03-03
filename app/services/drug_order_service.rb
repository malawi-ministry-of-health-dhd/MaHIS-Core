# frozen_string_literal: true

module DrugOrderService
  ORDER_PARAMS = %i[order_type_id concept_id orderer encounter_id start_date
                    auto_expire_date discontinued_date patient_id
                    accession_number obs_id program_id].freeze

  DRUG_ORDER_PARAMS = %i[drug_inventory_id].freeze

  FIND_FILTERS = ORDER_PARAMS + DRUG_ORDER_PARAMS

  DATETIME_FIELDS = %i[start_date auto_expire_date discontinued_date].freeze

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

    def fetch_all_patient_drug_orders(patient_id)
      # Quote patient ID for SQL safety
      quoted_patient_id = ActiveRecord::Base.connection.quote(patient_id)
    
      # Query to fetch all drug orders for the patient
      medication = ActiveRecord::Base.connection.select_all <<-SQL
        SELECT
          d.name AS drug_name,
          t.quantity AS quantity,
          o.start_date AS start_date,
          o.auto_expire_date AS expire_date,
          o.order_id AS order_id,
          t.drug_inventory_id AS drug_id,
          e.encounter_id AS encounter_id,
          e.encounter_datetime AS encounter_date,
          t.frequency AS frequency,
          t.prn AS prn,
          t.dose AS dose,
          t.units AS units,
          t.equivalent_daily_dose AS equivalent_daily_dose,
          e.program_id AS program_id
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
          order_id: m['order_id'],
          drug_id: m['drug_id'],
          encounter_id: m['encounter_id'],
          encounter_date: m['encounter_date'],
          frequency: m['frequency'],
          prn: m['prn'],
          dose: m['dose'],
          units: m['units'],
          equivalent_daily_dose: m['equivalent_daily_dose'],
          program_id: m['program_id']
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

    private

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
      Rails.logger.debug "=== CREATE ORDER START ==="
      Rails.logger.debug "create_params: #{create_params.inspect}"
      
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

      Rails.logger.debug "=== ORDER CREATED: #{order.id}, errors: #{order.errors.full_messages} ==="

      if create_params[:batch_number].present?
        concept_id = ConceptName.find_by_name!('Batch Number').concept_id
        Rails.logger.debug "=== USING BATCH NUMBER concept_id: #{concept_id} ==="
      else
        concept = ConceptName.find_by_name('Drug end date')
        Rails.logger.debug "=== Drug end date concept lookup: #{concept.inspect} ==="  # KEY LOG
        concept_id = concept&.concept_id
      end

      Rails.logger.debug "=== CREATING OBSERVATION with concept_id: #{concept_id} ==="

      obs = Observation.create!(
        concept_id: concept_id,
        encounter:,
        person_id: encounter.patient_id,
        order:,
        obs_datetime: start_date,
        value_datetime: drug_runout_date,
        value_text: create_params[:batch_number].present? ? create_params[:batch_number] : nil,
        comments: create_params[:batch_number].present? ? 'Batch Number for drug ordered' : 'User specified drug run out date during drug prescription',
        location_id: User.current.location_id
      )

      Rails.logger.debug "=== OBSERVATION CREATED: #{obs.id} ==="

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
