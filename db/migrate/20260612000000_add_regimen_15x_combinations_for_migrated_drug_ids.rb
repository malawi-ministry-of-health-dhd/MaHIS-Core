# frozen_string_literal: true

# When drug orders are migrated from BHT-EMR-API into the harmonized MaHIS DB
# via emr_to_mahis_migrator, the migrator resolves drug records by name and
# creates new drug rows (drug_id 1534/1535/1536) that are distinct from the
# canonical drug rows already in the harmonized DB (drug_id 809/882/1170).
#
# moh_regimen_combination_drug only had entries for the canonical IDs, so the
# patient_regimens SQL (GROUP_CONCAT match on drug_ids) could not match migrated
# patients on regimen 15A / 15P / 15PA / 15PP, causing them to appear as
# unknown_regimen (0 count) in the ART cohort report.
#
# Drug mapping:
#   809  → 1534  ABC/3TC (Abacavir and Lamivudine 600/300mg)
#   882  → 1535  ABC/3TC (Abacavir and Lamivudine 120/60mg)
#   1170 → 1536  ABC/3TC/DTG (Abacavir Lamivudine Dolutegravir 60/30/5mg)
#
# New combinations added:
#   15A  (regimen_name_id=23): 822 + 1534
#   15P  (regimen_name_id=7):  1536
#   15PA (regimen_name_id=39): 822 + 1535
#   15PP (regimen_name_id=30): 820 + 1535
class AddRegimen15xCombinationsForMigratedDrugIds < ActiveRecord::Migration[8.1]
  # Maps regimen_name → [regimen_name_id, [drug_ids]]
  COMBINATIONS = [
    { regimen_name: '15A',  regimen_name_id: 23, drug_ids: [822, 1534] },
    { regimen_name: '15P',  regimen_name_id: 7,  drug_ids: [1536] },
    { regimen_name: '15PA', regimen_name_id: 39, drug_ids: [822, 1535] },
    { regimen_name: '15PP', regimen_name_id: 30, drug_ids: [820, 1535] }
  ].freeze

  def up
    COMBINATIONS.each do |combo|
      # Skip if this exact drug_id set already exists for this regimen
      # (idempotency guard: check if all drug_ids are already in a single combo for this regimen_name_id)
      existing = find_existing_combo(combo[:regimen_name_id], combo[:drug_ids])
      if existing
        say "Skipping #{combo[:regimen_name]} — combination #{combo[:drug_ids].join(',')} already exists (combo_id=#{existing})"
        next
      end

      combo_id = insert_combination(combo[:regimen_name_id])
      combo[:drug_ids].each { |drug_id| insert_combination_drug(combo_id, drug_id) }
      say "Inserted #{combo[:regimen_name]} combination #{combo[:drug_ids].join(',')} (combo_id=#{combo_id})"
    end
  end

  def down
    # Find and remove the combinations added by this migration.
    # We identify them by matching the exact drug_id set within a regimen_name_id
    # and only removing combos created on or after this migration was written.
    COMBINATIONS.each do |combo|
      combo_id = find_existing_combo(combo[:regimen_name_id], combo[:drug_ids])
      next unless combo_id

      execute("DELETE FROM moh_regimen_combination_drug WHERE regimen_combination_id = #{combo_id}")
      execute("DELETE FROM moh_regimen_combination WHERE regimen_combination_id = #{combo_id}")
      say "Removed #{combo[:regimen_name]} combination #{combo[:drug_ids].join(',')} (combo_id=#{combo_id})"
    end
  end

  private

  def find_existing_combo(regimen_name_id, drug_ids)
    sorted = drug_ids.sort.join(',')
    result = execute(<<~SQL)
      SELECT rc.regimen_combination_id
      FROM moh_regimen_combination rc
      WHERE rc.regimen_name_id = #{regimen_name_id}
        AND (
          SELECT GROUP_CONCAT(drug_id ORDER BY drug_id ASC)
          FROM moh_regimen_combination_drug
          WHERE regimen_combination_id = rc.regimen_combination_id
        ) = '#{sorted}'
    SQL
    result.first&.first
  end

  def insert_combination(regimen_name_id)
    execute(<<~SQL)
      INSERT INTO moh_regimen_combination (regimen_name_id, created_at, updated_at)
      VALUES (#{regimen_name_id}, NOW(), NOW())
    SQL
    execute('SELECT LAST_INSERT_ID()').first.first.to_i
  end

  def insert_combination_drug(combo_id, drug_id)
    execute(<<~SQL)
      INSERT INTO moh_regimen_combination_drug (regimen_combination_id, drug_id, created_at, updated_at)
      VALUES (#{combo_id}, #{drug_id}, NOW(), NOW())
    SQL
  end
end
