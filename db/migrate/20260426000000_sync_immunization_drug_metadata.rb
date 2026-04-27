# frozen_string_literal: true

require "securerandom"

class SyncImmunizationDrugMetadata < ActiveRecord::Migration[7.0]
  LEGACY_NAME_OVERRIDES = {
    "DTP-HepB-Hib vac" => "DPT-HepB-Hib_vac"
  }.freeze

  SUPPLEMENTAL_DRUGS = [
    { concept_name: "Albendazole", drug_name: "Albendazole (500mg tablet)" }
  ].freeze

  def up
    immunizations_set_id = select_value("SELECT concept_id FROM concept_name WHERE name = 'Immunizations' LIMIT 1")
    raise "Concept set 'Immunizations' not found" if immunizations_set_id.blank?

    creator_id = select_value("SELECT user_id FROM users ORDER BY user_id ASC LIMIT 1").to_i
    creator_id = 1 if creator_id <= 0

    concept_members = exec_query(<<~SQL).to_a
      SELECT DISTINCT cs.concept_id, cn.name AS concept_name
      FROM concept_set cs
      INNER JOIN concept_name cn ON cn.concept_id = cs.concept_id
      WHERE cs.concept_set = #{quote(immunizations_set_id)}
        AND cn.concept_name_type = 'FULLY_SPECIFIED'
    SQL

    created = 0
    renamed = 0
    untouched = 0

    concept_members.each do |member|
      concept_id = member["concept_id"].to_i
      concept_name = member["concept_name"].to_s.strip
      next if concept_name.empty?

      desired_name = LEGACY_NAME_OVERRIDES.fetch(concept_name, concept_name)
      active_drugs = exec_query(<<~SQL).to_a
        SELECT drug_id, name
        FROM drug
        WHERE concept_id = #{concept_id}
          AND retired = 0
        ORDER BY drug_id
      SQL

      if active_drugs.empty?
        insert_drug!(concept_id:, name: desired_name, creator_id:, units: "")
        created += 1
        say("Created drug for concept #{concept_id}: #{desired_name}")
        next
      end

      # Keep multi-formulation concepts (e.g. Albendazole) unchanged.
      if active_drugs.length == 1 && active_drugs.first["name"].to_s.strip != desired_name
        drug_id = active_drugs.first["drug_id"].to_i
        old_name = active_drugs.first["name"].to_s

        execute <<~SQL
          UPDATE drug
          SET name = #{quote(desired_name)}
          WHERE drug_id = #{drug_id}
        SQL

        renamed += 1
        say("Renamed drug ##{drug_id}: '#{old_name}' -> '#{desired_name}'")
      else
        untouched += 1
      end
    end

    SUPPLEMENTAL_DRUGS.each do |extra|
      exists = select_value(<<~SQL)
        SELECT 1
        FROM drug
        WHERE name = #{quote(extra[:drug_name])}
          AND retired = 0
        LIMIT 1
      SQL
      next if exists.present?

      concept_id = select_value(<<~SQL)
        SELECT concept_id
        FROM concept_name
        WHERE name = #{quote(extra[:concept_name])}
        LIMIT 1
      SQL
      next if concept_id.blank?

      fallback_units = select_value(<<~SQL)
        SELECT units
        FROM drug
        WHERE concept_id = #{concept_id.to_i}
          AND retired = 0
          AND units IS NOT NULL
          AND TRIM(units) != ''
        LIMIT 1
      SQL

      insert_drug!(
        concept_id: concept_id.to_i,
        name: extra[:drug_name],
        creator_id:,
        units: fallback_units.to_s
      )

      created += 1
      say("Created supplemental drug for concept #{concept_id}: #{extra[:drug_name]}")
    end

    say("Immunization drug metadata sync complete: created=#{created}, renamed=#{renamed}, untouched=#{untouched}")
  end

  def down
    # No-op: data migration is intentionally irreversible.
  end

  private

  def insert_drug!(concept_id:, name:, creator_id:, units:)
    execute <<~SQL
      INSERT INTO drug (
        concept_id,
        name,
        creator,
        date_created,
        retired,
        units,
        uuid
      ) VALUES (
        #{concept_id},
        #{quote(name)},
        #{creator_id},
        NOW(),
        0,
        #{quote(units)},
        #{quote(SecureRandom.uuid)}
      )
    SQL
  end
end
