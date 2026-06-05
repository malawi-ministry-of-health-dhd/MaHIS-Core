# frozen_string_literal: true

# Two-part fix for missing ARV coverage in harmonized:
#
# Part 1 — Adds 11 ARV drug rows that exist in openmrs_a18 but are absent from
# harmonized (INSERT IGNORE, safe to re-run).
#
# Part 2 — The emr_to_mahis_migrator mapped drug concept_ids to abbreviated
# concept names in harmonized (e.g. concept 55966 "ABC/3TC") rather than the
# full-name concepts (e.g. 55967 "Abacavir Lamivudine"). harmonized's arv_drug
# VIEW resolves membership via concept_set, and only the full-name concepts are
# in that set. The 9 abbreviation concept_ids are therefore invisible to the view,
# causing every drug_order written against the migrated drugs (575, 576, 809…)
# to be silently excluded from ARV queries — a gap of 6 295 orders.
#
# Fix follows the openmrs_a18 pattern: one canonical concept_id per regimen,
# shared by all formulations. We UPDATE drug.concept_id on the 11 affected drugs
# to point to the full-name concept already in the ARV concept_set. No concept_set
# changes needed — the arv_drug VIEW resolves them automatically after the update.
#
# concept_id values in Part 1 are remapped to their harmonized full-name
# equivalents (matched by FULLY_SPECIFIED concept name). dosage_form concept
# 4020 (Tablet in openmrs_a18) maps to 53225 in harmonized.
class AddMissingArvDrugsFromOpenmrsA18 < ActiveRecord::Migration[6.1]
  # rubocop:disable Metrics/MethodLength
  def up
    # Use raw SQL to bypass model validations (legacy drug data has nil dosage_form
    # which conflicts with the non-optional belongs_to :form association added in Rails 5+).
    # dosage_form 4020 (Tablet) in openmrs_a18 → 53225 in harmonized (matched by concept name).
    execute <<~SQL
      INSERT IGNORE INTO drug
        (concept_id, name, combination, dosage_form, dose_strength,
         maximum_daily_dose, minimum_daily_dose, route, units,
         creator, date_created, retired, uuid)
      VALUES
        -- Abacavir Lamivudine (concept 55967)
        (55967, 'ABC/3TC (Abacavir and Lamivudine 60/30mg tablet)',               1, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, 'b9fc7316-8d80-11d8-abbb-0024217bb78e'),
        (55967, 'ABC/3TC (Abacavir and Lamivudine 600/300mg tablet)',              0, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, 'b9ff6e86-8d80-11d8-abbb-0024217bb78e'),
        (55967, 'ABC/3TC (Abacavir and Lamivudine 120/60mg tablet)',               0, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, 'ff3db7a2-0818-4c9d-aafb-75d683103a82'),
        -- Abacavir Lamivudine Dolutegravir (concept 49267) — dosage_form Tablet → 53225
        (49267, 'ABC/3TC/DTG (Abacavir Lamivudine Dolutegravir 60/30/5mg tablet)', 0, 53225, 1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, '48550715-147f-11f0-bf28-201e88d1d747'),
        -- Atazanavir (concept 32325)
        (32325, 'ATV/(Atazanavir)',                                                0, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, 'b9ff5f72-8d80-11d8-abbb-0024217bb78e'),
        -- Lopinavir and Ritonavir pellets (concept 57432)
        (57432, 'LPV/r pellets',                                                   0, NULL,  1, NULL, NULL, NULL, 'caps',   1, '2004-01-01', 0, '5feba6b8-b5c3-4df9-a5d4-3629f053239a'),
        -- Tenofavir Lamivudine (concept 55970)
        (55970, 'TDF/3TC (Tenofavir and Lamivudine 300/300mg tablet',              1, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, 'b9fc73f2-8d80-11d8-abbb-0024217bb78e'),
        -- Tenofovir Lamivudine Atazanavir Ritonavir (concept 57083) — retired in source
        (57083, 'TDF/3TC + ALT/r',                                                 1, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 1, 'b9fed034-8d80-11d8-abbb-0024217bb78e'),
        -- Tenofovir stavudine (concept 56417)
        (56417, 'TDF/d4T (Tenofavir and Stavudine 300/300mg tablet',               1, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, 'b9fde03e-8d80-11d8-abbb-0024217bb78e'),
        -- Zidovudine Lamivudine Atazanavir Ritonavir (concept 57085) — retired in source
        (57085, 'AZT/3TC + ALT/r',                                                 1, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 1, 'b9fed1a6-8d80-11d8-abbb-0024217bb78e'),
        -- Zidovudine Lamivudine Tenofovir Lopinavir Ritonavir (concept 55074)
        (55074, 'AZT/3TC/TDF/LPV/r',                                               1, NULL,  1, NULL, NULL, NULL, 'tab(s)', 1, '2004-01-01', 0, 'b9fde1f6-8d80-11d8-abbb-0024217bb78e')
    SQL

    # Part 2: consolidate drugs onto the single canonical concept_id per regimen,
    # mirroring the openmrs_a18 pattern where all formulations of a regimen share
    # one concept_id that is already a member of the ARV concept_set.
    #
    # The migrator mapped drugs to abbreviated concept_ids (e.g. 55966 "ABC/3TC")
    # instead of the full-name ones already in the ARV concept_set (e.g. 55967
    # "Abacavir Lamivudine"). Updating drug.concept_id is the clean fix — no
    # concept_set surgery needed, and the arv_drug VIEW resolves them automatically.
    #
    # abbreviation concept_id → canonical (full-name) concept_id already in ARV set
    execute 'UPDATE drug SET concept_id = 55967 WHERE concept_id = 55966' # ABC/3TC
    execute 'UPDATE drug SET concept_id = 49267 WHERE concept_id = 49266' # ABC/3TC/DTG
    execute 'UPDATE drug SET concept_id = 32325 WHERE concept_id = 57138' # ATV (Atazanavir)
    execute 'UPDATE drug SET concept_id = 57432 WHERE concept_id = 57431' # LPV/r pellets
    execute 'UPDATE drug SET concept_id = 55970 WHERE concept_id = 55969' # TDF/3TC
    execute 'UPDATE drug SET concept_id = 57083 WHERE concept_id = 57082' # TDF/3TC + ATV/r
    execute 'UPDATE drug SET concept_id = 56417 WHERE concept_id = 56416' # TDF/d4T
    execute 'UPDATE drug SET concept_id = 57085 WHERE concept_id = 57084' # AZT/3TC + ATV/r
    execute 'UPDATE drug SET concept_id = 55074 WHERE concept_id = 55073' # AZT/3TC/TDF/LPV/r
  end
  # rubocop:enable Metrics/MethodLength

  def down
    uuids = %w[
      b9fc7316-8d80-11d8-abbb-0024217bb78e
      b9ff6e86-8d80-11d8-abbb-0024217bb78e
      ff3db7a2-0818-4c9d-aafb-75d683103a82
      48550715-147f-11f0-bf28-201e88d1d747
      b9ff5f72-8d80-11d8-abbb-0024217bb78e
      5feba6b8-b5c3-4df9-a5d4-3629f053239a
      b9fc73f2-8d80-11d8-abbb-0024217bb78e
      b9fed034-8d80-11d8-abbb-0024217bb78e
      b9fde03e-8d80-11d8-abbb-0024217bb78e
      b9fed1a6-8d80-11d8-abbb-0024217bb78e
      b9fde1f6-8d80-11d8-abbb-0024217bb78e
    ]
    Drug.unscoped.where(uuid: uuids).delete_all

    # Reverse Part 2: restore the abbreviation concept_ids on the migrated drugs
    execute 'UPDATE drug SET concept_id = 55966 WHERE concept_id = 55967 AND drug_id IN (575, 809, 882)'
    execute 'UPDATE drug SET concept_id = 49266 WHERE concept_id = 49267 AND drug_id IN (1170)'
    execute 'UPDATE drug SET concept_id = 57138 WHERE concept_id = 32325 AND drug_id IN (792)'
    execute 'UPDATE drug SET concept_id = 57431 WHERE concept_id = 57432 AND drug_id IN (819)'
    execute 'UPDATE drug SET concept_id = 55969 WHERE concept_id = 55970 AND drug_id IN (576)'
    execute 'UPDATE drug SET concept_id = 57082 WHERE concept_id = 57083 AND drug_id IN (773)'
    execute 'UPDATE drug SET concept_id = 56416 WHERE concept_id = 56417 AND drug_id IN (655)'
    execute 'UPDATE drug SET concept_id = 57084 WHERE concept_id = 57085 AND drug_id IN (774)'
    execute 'UPDATE drug SET concept_id = 55073 WHERE concept_id = 55074 AND drug_id IN (657)'
  end
end
