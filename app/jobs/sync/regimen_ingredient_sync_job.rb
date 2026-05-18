# frozen_string_literal: true

module Sync
  class RegimenIngredientSyncJob < BaseSyncJob
    DB_NAME = 'regimens'

    def perform(_batch_size = DEFAULT_BULK_BATCH_SIZE)
      engine = ArtService::RegimenEngine.new(program: Program.find_by_name('HIV Program'))
      bands  = weight_bands

      Sidekiq.logger.info "Pre-computing regimens for #{bands.size} weight bands"

      documents = bands.map do |min_weight, max_weight|
        regimens = engine.find_regimens(patient_weight: min_weight)

        {
          '_id'        => "regimen_band_#{min_weight}_#{max_weight}",
          'min_weight' => min_weight,
          'max_weight' => max_weight,
          'regimens'   => serialize_regimens(regimens)
        }
      end

      ensure_database_exists(DB_NAME)
      documents.each do |doc|
        sync_to_couchdb(doc, DB_NAME, doc['_id'])
      end

      Sidekiq.logger.info "Synced #{documents.size} regimen band documents to CouchDB '#{DB_NAME}'"
    end

    private

    # Distinct weight bands from active ingredients — each band uses min_weight
    # as the representative weight for RegimenEngine#find_regimens (which applies
    # min_weight <= weight <= max_weight, so the lower bound always selects the
    # correct ingredient set for that band).
    def weight_bands
      ActiveRecord::Base.connection.exec_query(<<~SQL).map { |r| [r['min_weight'], r['max_weight']] }.uniq
        SELECT DISTINCT min_weight, max_weight
        FROM moh_regimen_ingredient
        WHERE ingredient_active = 1 AND voided = 0
        ORDER BY min_weight, max_weight
      SQL
    end

    def serialize_regimens(regimens)
      regimens.transform_values do |drugs|
        drugs.map do |drug|
          {
            'drug_id'               => drug[:drug_id],
            'concept_id'            => drug[:concept_id],
            'drug_name'             => drug[:drug_name],
            'alternative_drug_name' => drug[:alternative_drug_name],
            'am'                    => drug[:am],
            'noon'                  => drug[:noon],
            'pm'                    => drug[:pm],
            'units'                 => drug[:units],
            'concept_name'          => drug[:concept_name],
            'pack_size'             => drug[:pack_size],
            'barcodes'              => drug[:barcodes],
            'regimen_category'      => drug[:regimen_category],
            'frequency'             => drug[:frequency],
            'drug_type'             => drug[:drug_type]
          }
        end
      end
    end
  end
end

# Usage:
# Sync::RegimenIngredientSyncJob.perform_async
# rails "sync:run[RegimenIngredientSyncJob]"
