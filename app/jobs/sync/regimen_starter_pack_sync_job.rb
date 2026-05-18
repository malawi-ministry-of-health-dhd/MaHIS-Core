# frozen_string_literal: true

module Sync
  # Syncs pre-hydrated regimen starter pack ingredients to CouchDB
  # 
  # Each document contains fully denormalized drug data (name, dose, pack_size, barcodes, etc.)
  # so the frontend can query offline without additional JOINs:
  #
  # Frontend pseudo-code:
  #   db.allDocs({
  #     startkey: "regimen_1A_#{weight}",
  #     endkey: "regimen_1A_#{weight}_\ufff0",
  #     include_docs: true
  #   })
  class RegimenStarterPackSyncJob < BaseSyncJob
    DB_NAME = 'regimen_starter_packs'

    def perform(_batch_size = DEFAULT_BULK_BATCH_SIZE)
      hiv_program = Program.find_by_name('HIV Program')
      raise 'HIV Program not found' unless hiv_program

      regimen_engine = ArtService::RegimenEngine.new(program: hiv_program)

      Sidekiq.logger.info "Syncing regimen starter packs to CouchDB '#{DB_NAME}'"

      # Query all starter pack ingredients with their regimen and drug data
      ingredients = MohRegimenIngredientStarterPack
                    .joins(:regimen, :drug)
                    .includes(:regimen, :drug, :dose)

      documents = ingredients.map do |ingredient|
        regimen_index = ingredient.regimen.regimen_index
        min_weight = ingredient.min_weight.to_f.round(1)
        max_weight = ingredient.max_weight.to_f.round(1)

        # Use ingredient_to_drug pattern from RegimenEngine
        drug_data = hydrate_ingredient(ingredient, regimen_engine)

        {
          '_id'          => "regimen_#{regimen_index}_#{format('%.1f', min_weight)}_#{format('%.1f', max_weight)}_#{ingredient.id}",
          'regimen_index' => regimen_index,
          'min_weight'   => min_weight,
          'max_weight'   => max_weight,
          'drug_inventory_id' => ingredient.drug_inventory_id,
          'drug'         => drug_data,
          'synced_at'    => Time.current.iso8601
        }
      end

      Sidekiq.logger.info "Prepared #{documents.size} starter pack documents"

      ensure_database_exists(DB_NAME)
      
      # Bulk sync for efficiency
      bulk_sync_to_couchdb(documents, DB_NAME)

      Sidekiq.logger.info "Successfully synced #{documents.size} regimen starter pack documents to CouchDB '#{DB_NAME}'"
    end

    private

    def hydrate_ingredient(ingredient, regimen_engine)
      drug = ingredient.drug
      regimen_category_lookup = MohRegimenLookup.find_by(drug_inventory_id: ingredient.drug_inventory_id)
      regimen_category = regimen_category_lookup ? regimen_category_lookup.regimen_name[-1] : nil
      
      # Starter packs don't have course attribute like regular ingredients
      # Default to Daily dosing
      frequency = 'Daily (QOD)'

      {
        'drug_id'               => drug.drug_id,
        'concept_id'            => drug.concept_id,
        'drug_name'             => drug.name,
        'alternative_drug_name' => drug.alternative_names.first&.short_name,
        'am'                    => ingredient.dose.am,
        'noon'                  => 0,
        'pm'                    => ingredient.dose.pm,
        'units'                 => drug.units,
        'concept_name'          => drug.concept.concept_names[0].name,
        'pack_size'             => drug.drug_cms&.pack_size,
        'barcodes'              => drug.barcodes.collect { |barcode| { 'tabs' => barcode.tabs } },
        'regimen_category'      => regimen_category,
        'frequency'             => frequency,
        'drug_type'             => regimen_engine.find_drug_type(drug)
      }
    end
  end
end

# Usage examples:
# Sync::RegimenStarterPackSyncJob.perform_async
# rails "sync:run[RegimenStarterPackSyncJob]"
