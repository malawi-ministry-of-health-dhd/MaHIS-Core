# frozen_string_literal: true

# Speeds up the "awaiting dispensation" and "awaiting lab results" queues.
# Both run a per-order NOT EXISTS check against obs of the form:
#   obs.order_id = ? AND obs.voided = 0 AND obs.concept_id IN (?)
# The existing single-column obs_order(order_id) index still requires scanning
# every obs row for that order to test concept_id/voided. This composite index
# turns each check into a single index seek.
class AddObsOrderConceptVoidedIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :obs, %i[order_id concept_id voided],
              name: 'idx_obs_order_concept_voided',
              if_not_exists: true
  end
end
