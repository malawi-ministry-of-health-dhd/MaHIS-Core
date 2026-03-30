# frozen_string_literal: true

require_relative '../../../../../config/drugs'

module ArtService
  module Reports
    module Pepfar
      # This class is used to generate the SC_CURR report
      # The current number of ARV drug units (bottles) at the end of the reporting period by ARV drug category
      class ScCurr
        DRUG_CATEGORY = {
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

        def initialize(start_date:, end_date:, **_kwargs)
          @start_date = start_date
          @end_date = end_date
        end

        def find_report
          initialize_report
          process_report
          # remove the drug_id from the report
          @report.each { |category| category.delete(:drug_id) }
          @report
        end

        private

        def initialize_report
          @report = []
          DRUG_CATEGORY.each do |category, drug|
            @report << {
              category:,
              drug_id: drug[:drugs],
              units: 0,
              quantity: drug[:quantity],
              granular_spec: []
            }
          end
        end

        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/CyclomaticComplexity
        def process_report
          current_stock.each do |item|
            # Find the drug category
            drug_category = @report.find do |category|
              category[:drug_id].include?(item.drug_id) && category[:quantity] == item.pack_size
            end
            drug_category ||= @report.find do |category|
              category[:drug_id].include?(item.drug_id) && category[:quantity] == 'N/A'
            end
            next unless drug_category

            bottles = (item.current_quantity / item.pack_size).to_i
            drug_category[:units] += bottles
            # check if the drug is already in the granular_spec
            granular_spec = drug_category[:granular_spec].find { |spec| spec[:drug_name] == item.drug.name }
            if granular_spec
              granular_spec[:units] += bottles
            else
              drug_category[:granular_spec] << {
                drug_name: item.drug.name,
                units: bottles
              }
            end
          end
        end
        # rubocop:enable Metrics/AbcSize
        # rubocop:enable Metrics/CyclomaticComplexity

        def current_stock
          drugs = DRUG_CATEGORY.map { |_, drug| drug[:drugs] }.flatten.uniq
          PharmacyBatchItem.where(
            'expiry_date >= ? AND delivery_date <= ? AND drug_id IN (?) AND current_quantity > 0', @end_date, @end_date, drugs
          )
        end
      end
    end
  end
end
