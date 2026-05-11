# frozen_string_literal: true

module Sync
  class CustomRegimenIngredientSyncJob < BaseSyncJob
    DB_NAME = 'custom_regimen_ingredients'

    def perform(_batch_size = DEFAULT_BULK_BATCH_SIZE)
      engine = ArtService::RegimenEngine.new(program: Program.find_by_name('HIV Program'))
      drugs  = engine.custom_regimen_ingredients

      # Eager-load associations to avoid N+1 when calling as_json
      drug_ids = drugs.map(&:drug_id)
      drugs_with_associations = Drug.includes(:alternative_names, :barcodes)
                                    .where(drug_id: drug_ids)
                                    .index_by(&:drug_id)

      documents = drug_ids.map do |drug_id|
        drug = drugs_with_associations[drug_id]
        next unless drug

        drug.as_json.merge('_id' => "custom_regimen_ingredient_#{drug.drug_id}")
      end.compact

      ensure_database_exists(DB_NAME)
      documents.each { |doc| sync_to_couchdb(doc, DB_NAME, doc['_id']) }

      Sidekiq.logger.info "Synced #{documents.size} custom regimen ingredient documents to CouchDB '#{DB_NAME}'"
    end
  end
end

# Usage:
# Sync::CustomRegimenIngredientSyncJob.perform_async
# rails "sync:run[CustomRegimenIngredientSyncJob]"
