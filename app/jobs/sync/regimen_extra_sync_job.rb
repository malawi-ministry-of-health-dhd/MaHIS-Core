# frozen_string_literal: true

module Sync
  class RegimenExtraSyncJob < BaseSyncJob
    DB_NAME = 'regimen_extras'

    def perform(batch_size = DEFAULT_BULK_BATCH_SIZE)
      engine = ArtService::RegimenEngine.new(program: Program.find_by_name('HIV Program'))
      bands  = weight_bands

      Sidekiq.logger.info "Pre-computing regimen extras for #{bands.size} weight bands"

      documents = bands.map do |min_weight, max_weight|
        extras = engine.regimen_extras(patient_weight: min_weight)

        {
          '_id'        => "regimen_extra_band_#{min_weight}_#{max_weight}",
          'min_weight' => min_weight,
          'max_weight' => max_weight,
          'extras'     => serialize_extras(extras)
        }
      end

      sync_array_to_couchdb(documents, DB_NAME, 'regimen_extra', batch_size)
    end

    private

    # The array helper passes already-built documents straight through.
    def prepare_document(document)
      document
    end

    def generate_document_id(document)
      document['_id']
    end

    def weight_bands
      ActiveRecord::Base.connection.exec_query(<<~SQL).map { |r| [r['min_weight'], r['max_weight']] }.uniq
        SELECT DISTINCT min_weight, max_weight
        FROM moh_regimen_ingredient
        WHERE ingredient_active = 1 AND voided = 0
        ORDER BY min_weight, max_weight
      SQL
    end

    def serialize_extras(extras)
      extras.map do |drug|
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
          'frequency'             => drug[:frequency]
        }
      end
    end
  end
end

# Usage:
# Sync::RegimenExtraSyncJob.perform_async
# rails "sync:run[RegimenExtraSyncJob]"
