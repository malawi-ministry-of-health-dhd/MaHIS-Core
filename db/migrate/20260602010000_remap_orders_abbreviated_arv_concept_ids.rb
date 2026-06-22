# frozen_string_literal: true

# The emr_to_mahis_migrator wrote drug orders using abbreviated concept_ids
# (e.g. 55966 "ABC/3TC") instead of the canonical full-name concept_ids already
# in the ARV concept_set (e.g. 55967 "Abacavir Lamivudine").
#
# Migration 20260522090000_add_missing_arv_drugs_from_openmrs_a18 already fixed
# drug.concept_id for these regimens, but orders.concept_id still carries the old
# abbreviated values. The adherence classification query joins orders.concept_id
# against the ARV concept_set; orders with unrecognised concept_ids are silently
# excluded, causing those patients' adherence to appear unknown.
#
# This migration normalises orders.concept_id using the same abbreviated→canonical
# mapping as the drug-table fix. Also removes the temporary concept_set entry for
# concept 55966 that was inserted as a runtime workaround on 2026-06-02.
#
# abbreviated concept_id → canonical concept_id (already a member of ARV concept_set)
#   55966 → 55967  ABC/3TC        (Abacavir Lamivudine)
#   49266 → 49267  ABC/3TC/DTG    (Abacavir Lamivudine Dolutegravir)
#   57138 → 32325  ATV            (Atazanavir)
#   57431 → 57432  LPV/r pellets  (Lopinavir and Ritonavir pellets)
#   55969 → 55970  TDF/3TC        (Tenofovir Lamivudine)
#   57082 → 57083  TDF/3TC+ATV/r  (Tenofovir Lamivudine Atazanavir Ritonavir)
#   56416 → 56417  TDF/d4T        (Tenofovir stavudine)
#   57084 → 57085  AZT/3TC+ATV/r  (Zidovudine Lamivudine Atazanavir Ritonavir)
#   55073 → 55074  AZT/3TC/TDF/LPV/r
class RemapOrdersAbbreviatedArvConceptIds < ActiveRecord::Migration[8.1]
  # abbreviated → canonical (matches the drug-table remap in 20260522090000)
  REMAP = {
    55_966 => 55_967, # ABC/3TC
    49_266 => 49_267, # ABC/3TC/DTG
    57_138 => 32_325, # ATV
    57_431 => 57_432, # LPV/r pellets
    55_969 => 55_970, # TDF/3TC
    57_082 => 57_083, # TDF/3TC + ATV/r
    56_416 => 56_417, # TDF/d4T
    57_084 => 57_085, # AZT/3TC + ATV/r
    55_073 => 55_074  # AZT/3TC/TDF/LPV/r
  }.freeze

  def up
    REMAP.each do |old_id, new_id|
      execute "UPDATE orders SET concept_id = #{new_id} WHERE concept_id = #{old_id}"
      rows = select_value('SELECT ROW_COUNT()').to_i
      say "orders: concept_id #{old_id} → #{new_id}: #{rows} rows updated" if rows > 0
    end

    # Remove the temporary concept_set safety-net entry inserted on 2026-06-02.
    # With orders now pointing to canonical concept_ids, this entry is redundant.
    execute <<~SQL
      DELETE FROM concept_set
      WHERE concept_id = 55966
        AND concept_set = 37989
    SQL
    say "concept_set: removed temporary entry concept_id=55966 in set 37989 (#{select_value('SELECT ROW_COUNT()')} row)"
  end

  def down
    # Reverse orders.concept_id (best-effort — only for the drug_order type)
    REMAP.each do |old_id, new_id|
      execute "UPDATE orders SET concept_id = #{old_id} WHERE concept_id = #{new_id} AND order_type_id = 1"
    end

    # Re-insert the concept_set safety-net entry
    execute <<~SQL
      INSERT IGNORE INTO concept_set (concept_id, concept_set, sort_weight, creator, date_created, uuid)
      VALUES (55966, 37989, 39, 2, NOW(), UUID())
    SQL
  end
end
