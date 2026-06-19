# app/jobs/sync/specimen_sync_job.rb
module Sync
  class SpecimenSyncJob < BaseSyncJob
    def perform(batch_size = 50)
      specimens_data = get_specimens_with_test_types

      sync_array_to_couchdb(
        specimens_data,
        'specimens',
        'specimens',
        batch_size,
        progress_interval: 25,
        rate_limit_interval: 5
      )
    end

    private

    def get_specimens_with_test_types
      # Get attribute type IDs
      test_catalogue_type_id = ConceptAttributeType.test_catalogue_name.concept_attribute_type_id
      nlims_code_type_id = ConceptAttributeType.nlims_code.concept_attribute_type_id

      # Get all specimen types from the concept set
      specimen_type_concept = ConceptName.find_by_name(Lab::Metadata::SPECIMEN_TYPE_CONCEPT_NAME)
      return [] unless specimen_type_concept

      specimen_concept_ids = ConceptSet.where(concept_set: specimen_type_concept.concept_id)
                                       .pluck(:concept_id)
                                       .uniq

      return [] if specimen_concept_ids.empty?

      # Get all test types
      test_type_concept = ConceptName.find_by_name(Lab::Metadata::TEST_TYPE_CONCEPT_NAME)
      return [] unless test_type_concept

      test_type_concept_ids = ConceptSet.where(concept_set: test_type_concept.concept_id)
                                        .pluck(:concept_id)
                                        .uniq

      # Get all test type names
      test_type_names_map = ConceptName.where(concept_id: test_type_concept_ids, voided: 0)
                                       .pluck(:concept_id, :name)
                                       .to_h

      specimens = []

      # Build a map of specimen_id => [test_type_names]
      # Using the same logic as the API: concept_id = specimen, concept_set = test_type
      specimen_test_types = {}

      # Find all relationships where concept_id is a specimen and concept_set is a test type
      concept_set_relationships = ConceptSet.where(
        concept_id: specimen_concept_ids,
        concept_set: test_type_concept_ids
      ).select(:concept_id, :concept_set)

      concept_set_relationships.each do |rel|
        specimen_id = rel.concept_id
        test_type_id = rel.concept_set
        test_type_name = test_type_names_map[test_type_id]

        if test_type_name
          specimen_test_types[specimen_id] ||= []
          specimen_test_types[specimen_id] << test_type_name
        end
      end

      # Get specimen details with attributes - matching the API's SQL exactly
      specimen_details = ActiveRecord::Base.connection.select_all <<~SQL
        SELECT ca.concept_id, ca.value_reference as name, ca2.value_reference as nlims_code, c.uuid
          FROM concept_attribute ca
        INNER JOIN concept_attribute ca2 ON ca.concept_id = ca2.concept_id
          AND ca2.attribute_type_id = #{nlims_code_type_id}
        INNER JOIN concept c ON c.concept_id = ca.concept_id
        WHERE ca.attribute_type_id = #{test_catalogue_type_id}
        AND ca.concept_id IN (#{specimen_concept_ids.join(',')})
        GROUP BY ca.concept_id
      SQL

      specimen_details.each do |specimen|
        concept_id = specimen['concept_id']
        test_type_names = specimen_test_types[concept_id] || []

        # Create a document for each test_type relationship
        if test_type_names.any?
          test_type_names.each do |test_type_name|
            specimens << {
              concept_id: concept_id,
              uuid: specimen['uuid'],
              name: specimen['name'],
              nlims_code: specimen['nlims_code'],
              test_type: test_type_name
            }
          end
        else
          # Also include specimens without test types (for the general list)
          specimens << {
            concept_id: concept_id,
            uuid: specimen['uuid'],
            name: specimen['name'],
            nlims_code: specimen['nlims_code'],
            test_type: nil
          }
        end
      end

      specimens
    end

    def prepare_document(specimen)
      {
        'concept_id' => specimen[:concept_id],
        'uuid' => specimen[:uuid],
        'name' => specimen[:name],
        'nlims_code' => specimen[:nlims_code],
        'test_type' => specimen[:test_type]
      }
    end

    def generate_document_id(specimen)
      # Use a combination of concept_id and test_type to ensure uniqueness
      if specimen[:test_type]
        "specimen_#{specimen[:concept_id]}_#{specimen[:test_type].gsub(/[^a-zA-Z0-9]/, '_')}"
      else
        "specimen_#{specimen[:concept_id]}_all"
      end
    end
  end
end

# Usage examples:
# Sync::SpecimenSyncJob.perform_async     # Default batch size of 50
# Sync::SpecimenSyncJob.perform_async(25) # Smaller batches
# Sync::SpecimenSyncJob.perform_async(10) # Very small batches for careful processing
