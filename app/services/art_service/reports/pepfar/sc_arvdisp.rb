# frozen_string_literal: true

require_relative '../../../../../config/drugs'

module ArtService
  module Reports
    module Pepfar
      class ScArvdisp
        include CommonSqlQueryUtils

        DRUGCATEGORY = {
          'TLD 30-count bottles' => { drugs: Drugs.sc_curr_ids_for('TLD 30-count bottles'), quantity: 30 },
          'TLD 90-count bottles' => { drugs: Drugs.sc_curr_ids_for('TLD 90-count bottles'), quantity: 90 },
          'TLD 180-count bottles' => { drugs: Drugs.sc_curr_ids_for('TLD 180-count bottles'), quantity: 180 },
          'TLE/400 30-count bottles' => { drugs: Drugs.sc_curr_ids_for('TLE/400 30-count bottles'), quantity: 30 },
          'TLE/400 90-count bottles' => { drugs: Drugs.sc_curr_ids_for('TLE/400 90-count bottles'), quantity: 90 },
          'TLE 600/TEE bottles' => { drugs: Drugs.sc_curr_ids_for('TLE 600/TEE bottles'), quantity: 'N/A' },
          'DTG 10 90-count bottles' => { drugs: Drugs.sc_curr_ids_for('DTG 10 90-count bottles'), quantity: 90 },
          'DTG 50 30-count bottles' => { drugs: Drugs.sc_curr_ids_for('DTG 50 30-count bottles'), quantity: 30 },
          'LPV/r 100/25 tabs 60 tabs/bottle' => { drugs: Drugs.sc_curr_ids_for('LPV/r 100/25 tabs 60 tabs/bottle'), quantity: 60 },
          'LPV/r 40/10 (pediatrics) bottles' => { drugs: Drugs.sc_curr_ids_for('LPV/r 40/10 (pediatrics) bottles'), quantity: 'N/A' },
          'NVP (adult) bottles' => { drugs: Drugs.sc_curr_ids_for('NVP (adult) bottles'), quantity: 'N/A' },
          'NVP (pediatric) bottles' => { drugs: Drugs.sc_curr_ids_for('NVP (pediatric) bottles'), quantity: 'N/A' },
          'Other (adult) bottles' => { drugs: Drugs.sc_curr_ids_for('Other (adult) bottles'), quantity: 'N/A' },
          'Other (pediatric) bottles' => { drugs: Drugs.sc_curr_ids_for('Other (pediatric) bottles'), quantity: 'N/A' }
        }.freeze

        def initialize(start_date:, end_date:, rebuild_outcome: false, **kwargs)
          @completion_start_date = start_date.to_date.strftime('%Y-%m-%d 00:00:00')
          @completion_end_date = end_date.to_date.strftime('%Y-%m-%d 23:59:59')
          @rebuild_outcome = rebuild_outcome
          @use_filing_number = GlobalProperty.find_by(property: 'use.filing.numbers')
                                             &.property_value
                                             &.casecmp?('true')
          @occupation = kwargs[:occupation]
          @dsd = kwargs[:dsd]
          @location_id = User.current.location_id
        end

        def report
          data
        end

        private

        DRUG_CATEGORY = [
          { name: 'TLD 30-count bottles', units: 0, quantity: 30, dispensations: [] },
          { name: 'TLD 90-count bottles', units: 0, quantity: 90, dispensations: [] },
          { name: 'TLD 180-count bottles', units: 0, quantity: 180, dispensations: [] },
          { name: 'TLE/400 30-count bottles', units: 0, quantity: 30, dispensations: [] },
          { name: 'TLE/400 90-count bottles', units: 0, quantity: 90, dispensations: [] },
          { name: 'TLE 600/TEE bottles', units: 0, quantity: 'N/A', dispensations: [] },
          { name: 'DTG 10 90-count bottles', units: 0, quantity: 90, dispensations: [] },
          { name: 'DTG 50 30-count bottles', units: 0, quantity: 30, dispensations: [] },
          { name: 'LPV/r 100/25 tabs 60 tabs/bottle', units: 0, quantity: 60, dispensations: [] },
          { name: 'LPV/r 40/10 (pediatrics) bottles', units: 0, quantity: 'N/A', dispensations: [] },
          { name: 'NVP (adult) bottles', units: 0, quantity: 'N/A', dispensations: [] },
          { name: 'NVP (pediatric) bottles', units: 0, quantity: 'N/A', dispensations: [] },
          { name: 'Other (adult) bottles', units: 0, quantity: 'N/A', dispensations: [] },
          { name: 'Other (pediatric) bottles', units: 0, quantity: 'N/A', dispensations: [] }
          # {name: "Other bottles", units: 0, quantity: 'N/A', dispensations: []}
        ].freeze

        def data
          categories = DRUG_CATEGORY.map { |category| category.merge(dispensations: []) }

          (fetch_dispensations || {}).map do |_order_id, dispensation_info|
            quantities = dispensation_info[:quantities]

            (quantities || []).each do |quantity|
              fetched_category, unit = fetch_category(dispensation_info[:drug_id], quantity)
              categories.each do |category|
                next unless category[:name] == fetched_category

                category[:units] += unit
                category[:dispensations] << [
                  dispensation_info[:name],
                  quantity,
                  dispensation_info[:start_date],
                  dispensation_info[:identifier],
                  dispensation_info[:patient_id]
                ]
                break
              end
            end
          end

          categories
        end

        def fetch_category(drug_id, quantity)
          DRUGCATEGORY.map do |name, data|
            next unless data[:drugs].include?(drug_id)

            qty = data[:quantity]
            return [name, 1] if qty == 'N/A'
            return [name, 1] if qty.to_i == quantity.to_i
          end

          DRUGCATEGORY.map do |name, data|
            if data[:drugs].include?(drug_id)
              qty = data[:quantity]
              return [name, (quantity / qty).to_i] if (quantity.to_i % qty).zero?
            end
          end
          # return ["Other bottles", 1]
        end

        def fetch_dispensations
          dispensations = {}
          (fetch_orders || []).each do |order|
            order_id = order['order_id'].to_i
            assign_order_details(dispensations, order) if dispensations[order_id].blank?
            dispensations[order_id][:quantities] << order['value_numeric'].to_f
          end

          dispensations
        end

        def assign_order_details(report, order)
          order_id = order['order_id'].to_i
          report[order_id] = {
            quantity: order['quantity'].to_f,
            name: order['name'],
            drug_id: order['drug_id'].to_i,
            identifier: (order['identifier'] ||= 'N/A'),
            start_date: order['start_date'].to_date,
            patient_id: order['patient_id'].to_i,
            quantities: []
          }
        end

        def fetch_orders
          ActiveRecord::Base.connection.select_all <<~SQL
            SELECT
            	orders.order_id, orders.start_date, drug_order.quantity,drug.name,
            	orders.patient_id, obs.value_numeric, orders.start_date,
            	patient_identifier.identifier,drug.drug_id
            FROM orders
            INNER JOIN drug_order ON drug_order.order_id = orders.order_id AND drug_order.quantity > 0
            INNER JOIN arv_drug ON arv_drug.drug_id = drug_order.drug_inventory_id
            INNER JOIN drug ON drug.drug_id = arv_drug.drug_id
            INNER JOIN encounter ON encounter.encounter_id = orders.encounter_id
            AND encounter.program_id = #{Program.find_by(name: 'HIV Program').id}
            INNER JOIN patient_program pp ON pp.patient_id = orders.patient_id
              AND pp.program_id = #{Program.find_by(name: 'HIV Program').id}
              AND pp.voided = 0
              AND pp.location_id = #{@location_id}
            #{dsd_query(dsd: @dsd, model: 'orders') if @dsd}
            INNER JOIN obs ON obs.order_id = orders.order_id AND obs.voided = 0
            	AND obs.concept_id = #{amount_dispensed} AND obs.value_numeric > 0
            LEFT JOIN patient_identifier ON patient_identifier.patient_id = orders.patient_id
            	AND patient_identifier.identifier_type = #{identifier_type}
            	AND patient_identifier.voided = 0
            LEFT JOIN (#{current_occupation_query}) a ON a.person_id = orders.patient_id
            WHERE orders.voided = 0 #{%w[Military Civilian].include?(@occupation) ? 'AND' : ''} #{occupation_filter(occupation: @occupation, field_name: 'value', table_name: 'a', include_clause: false)}
            AND orders.start_date BETWEEN '#{@completion_start_date}' AND '#{@completion_end_date}'
            AND orders.order_type_id = 1 -- Drug order
            ORDER BY orders.start_date ASC, orders.patient_id;
          SQL
        end

        def amount_dispensed
          @amount_dispensed ||= ConceptName.find_by(name: 'Amount dispensed').concept_id
        end

        def identifier_type
          @identifier_type ||= PatientIdentifierType.find_by_name!(@use_filing_number ? 'Filing Number' : 'ARV Number').id
        end
      end
    end
  end
end
