# frozen_string_literal: true

# ============================================================
# IMPOW Drug Sync Job
# ============================================================
# Syncs all IMPOW (Integrated Management and Prevention of Oedema and Wasting)
# program drugs to CouchDB, including:
#   - SFP (Supplementary Feeding Services): RUSF, CSB+, CSB++
#   - OTS (Outpatient Therapeutic Services): RUTF, Amoxicillin, Albendazole, Mebendazole, Vitamin A, Measles-Rubella
#   - NRU (Inpatient Therapeutic Service): F-75, F-100, RUTF
#
# Creates both individual drug documents and a comprehensive reference document
# with dosage protocols for all programs.
# ============================================================

module Sync
  class ImpowDrugSyncJob < BaseSyncJob
    DB_NAME = 'impow_drugs'

    # The single reference document ID that holds all dosage tables for all IMPOW programs.
    # It is upserted on every sync so the latest protocol is always current.
    REFERENCE_DOC_ID = 'impow_drugs_reference'

    def perform(batch_size = DEFAULT_BULK_BATCH_SIZE)
      # 1. Sync individual Drug rows for all IMPOW programs (one CouchDB doc per Drug record)
      sync_impow_drugs(batch_size)

      # 2. Upsert the dosage-reference document (all IMPOW program dosage tables)
      upsert_reference_document
    end

    private

    def sync_impow_drugs(batch_size)
      # Sync SFP drugs
      sync_records_to_couchdb(Drug, DB_NAME, batch_size) do |model_class|
        model_class.find_all_by_concept_set('Supplementary Feeding Services')
      end

      # Sync OTS drugs
      sync_records_to_couchdb(Drug, DB_NAME, batch_size) do |model_class|
        model_class.find_all_by_concept_set('Outpatient Therapeutic Services')
      end

      # Sync NRU drugs
      sync_records_to_couchdb(Drug, DB_NAME, batch_size) do |model_class|
        model_class.find_all_by_concept_set('Inpatient Therapeutic Service')
      end
    end

    # ------------------------------------------------------------------
    # Individual drug documents (mirrors ArvDrugSyncJob structure)
    # ------------------------------------------------------------------

    def get_required_columns
      %i[drug_id concept_id name combination dosage_form dose_strength
         maximum_daily_dose minimum_daily_dose route units]
    end

    def prepare_document(drug)
      {
        'drug_id' => drug.drug_id,
        'concept_id' => drug.concept_id,
        'name' => drug.name,
        'combination' => drug.combination,
        'dosage_form' => drug.dosage_form,
        'dose_strength' => drug.dose_strength,
        'maximum_daily_dose' => drug.maximum_daily_dose,
        'minimum_daily_dose' => drug.minimum_daily_dose,
        'route' => drug.route,
        'units' => drug.units
      }
    end

    def generate_document_id(drug)
      "impow_drug_#{drug.drug_id}"
    end

    # ------------------------------------------------------------------
    # Dosage-reference document — the full lookup table in one document
    # ------------------------------------------------------------------

    def upsert_reference_document
      doc = build_reference_document
      sync_to_couchdb(doc, DB_NAME, REFERENCE_DOC_ID)
    end

    def build_reference_document
      {
        '_id' => REFERENCE_DOC_ID,
        'type' => 'impow_drug_reference',
        'version' => '1.0.0',
        'description' => 'IMPOW Nutrition Program Drug Dosages (SFP, OTS, NRU)',
        'created_at' => Time.current.to_date.iso8601,
        'programs' => {
          'sfp' => sfp_program_section,
          'ots' => ots_program_section,
          'nru' => nru_program_section
        },
        'views' => couchdb_views
      }
    end

    # ---- SFP (Supplementary Feeding Services) --------------------------

    def sfp_program_section
      concept_set = ConceptName.find_by(name: 'Supplementary Feeding Services')

      {
        'program_name' => 'Supplementary Feeding Services',
        'program_code' => 'SFP',
        'concept_set_id' => concept_set&.concept_id,
        'description' => 'Supplementary Feeding Program for moderate acute malnutrition',
        'drugs' => {
          'rusf' => rusf_sfp_section,
          'csb_plus' => csb_plus_section,
          'csb_plus_plus' => csb_plus_plus_section
        }
      }
    end

    def rusf_sfp_section
      concept_name = 'Ready-to-Use Supplementary Food (RUSF)'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Supplementary Feeding Services',
        'drugs' => drugs
      }
    end

    def csb_plus_section
      concept_name = 'Corn Soy Blend Plus (CSB+)'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Supplementary Feeding Services',
        'drugs' => drugs
      }
    end

    def csb_plus_plus_section
      concept_name = 'Corn Soy Blend Plus Plus (CSB++)'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Supplementary Feeding Services',
        'drugs' => drugs
      }
    end

    # ---- OTS (Outpatient Therapeutic Services) -------------------------

    def ots_program_section
      concept_set = ConceptName.find_by(name: 'Outpatient Therapeutic Services')

      {
        'program_name' => 'Outpatient Therapeutic Services',
        'program_code' => 'OTS',
        'concept_set_id' => concept_set&.concept_id,
        'description' => 'Outpatient treatment for severe acute malnutrition without medical complications',
        'drugs' => {
          'rutf' => rutf_section,
          'amoxicillin' => amoxicillin_section,
          'deworming' => deworming_section,
          'vitamin_a' => vitamin_a_section,
          'measles_rubella_vaccine' => measles_rubella_section
        }
      }
    end

    # Helper method to get all drugs for a concept by concept name
    # Returns array of drug hashes with drug_id, drug_name, and strength
    def get_drugs_by_concept_name(concept_name)
      concept = ConceptName.find_by(name: concept_name)
      return [] unless concept

      Drug.where(concept_id: concept.concept_id).map do |drug|
        {
          'drug_id' => drug.drug_id,
          'drug_name' => drug.name,
          'strength' => extract_strength(drug.name),
          'units' => drug.units,
          'dosage_form' => get_dosage_form_name(drug.dosage_form),
          'route' => get_route_name(drug.route)
        }
      end
    end

    # Helper method to get dosage form name from concept_id
    def get_dosage_form_name(dosage_form_concept_id)
      return nil unless dosage_form_concept_id

      ConceptName.find_by(concept_id: dosage_form_concept_id)&.name
    end

    # Helper method to get route name from concept_id
    def get_route_name(route_concept_id)
      return nil unless route_concept_id

      ConceptName.find_by(concept_id: route_concept_id)&.name
    end

    # Extract strength from drug name (e.g., "Amoxicillin (500mg tablet)" -> "500mg")
    def extract_strength(drug_name)
      match = drug_name.match(/\((\d+\s*(?:mg|g|mcg|IU|iu)).*?\)/i)
      match ? match[1] : nil
    end

    # ---- RUTF ----------------------------------------------------------

    def rutf_section
      concept_name = 'Ready-to-Use Therapeutic Food (RUTF)'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Outpatient Therapeutic Services',
        'drugs' => drugs,
        'dose_basis' => '165 kcal/kg/day',
        'note' => 'Dose given per day and per week based on weight band',
        'weight_bands' => Impow::OtsDrugDosageService.all_rutf_weight_bands.map do |band|
          {
            'min_kg' => band[:min],
            'max_kg' => band[:max] == Float::INFINITY ? nil : band[:max],
            'sachets_per_day' => band[:day],
            'sachets_per_week' => band[:week]
          }
        end
      }
    end

    # ---- Amoxicillin ---------------------------------------------------

    def amoxicillin_section
      concept_name = 'Amoxicillin'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Outpatient Therapeutic Services',
        'drugs' => drugs,
        'dose_range_mg_per_kg_per_day' => '25-50',
        'frequency' => 'twice daily',
        'duration_days' => 7,
        'when_given' => '1 dose at admission + 7 days at home for new enrollees only',
        'note' => 'Syrup can be given — check strength per 5 ml (2 strengths: 125 mg and 250 mg). ' \
                  'Ampicillin is given in the same dose if amoxicillin is not available.',
        'weight_bands' => Impow::OtsDrugDosageService.all_amoxicillin_weight_bands.map do |band|
          label = if band[:max] == Float::INFINITY
                    ">#{band[:min].to_i} kg"
                  elsif band[:min] == 0
                    "<#{(band[:max] + 0.1).to_i} kg"
                  else
                    "#{band[:min].to_i}-#{band[:max].to_i} kg"
                  end

          {
            'label' => label,
            'min_kg' => band[:min],
            'max_kg' => band[:max] == Float::INFINITY ? nil : band[:max],
            'dose_mg' => band[:dose_mg],
            'frequency' => 'twice daily',
            'recommended_drug_name' => band[:drug_name]
          }
        end
      }
    end

    # ---- Deworming -----------------------------------------------------

    def deworming_section
      albendazole_concept_name = 'Albendazole'
      mebendazole_concept_name = 'Mebendazole'

      albendazole_concept = ConceptName.find_by(name: albendazole_concept_name)
      albendazole_drugs = get_drugs_by_concept_name(albendazole_concept_name)

      mebendazole_concept = ConceptName.find_by(name: mebendazole_concept_name)
      mebendazole_drugs = get_drugs_by_concept_name(mebendazole_concept_name)

      {
        'concept_set' => 'Outpatient Therapeutic Services',
        'when_given' => '1 dose at enrollment — all patients',
        'note' => 'Either Albendazole OR Mebendazole is given, not both',
        'drugs' => {
          'albendazole' => {
            'concept_id' => albendazole_concept&.concept_id,
            'concept_name' => albendazole_concept_name,
            'drugs' => albendazole_drugs,
            'strength_mg' => 400,
            'age_bands' => format_deworming_age_bands(:albendazole)
          },
          'mebendazole' => {
            'concept_id' => mebendazole_concept&.concept_id,
            'concept_name' => mebendazole_concept_name,
            'drugs' => mebendazole_drugs,
            'strength_mg' => 500,
            'age_bands' => format_deworming_age_bands(:mebendazole)
          }
        }
      }
    end

    def format_deworming_age_bands(drug_key)
      Impow::OtsDrugDosageService.all_deworming_age_bands[drug_key].map do |band|
        {
          'label' => age_band_label(band[:min_months], band[:max_months]),
          'min_age_months' => band[:min_months],
          'max_age_months' => band[:max_months],
          'dose' => band[:dose],
          'dose_unit' => band[:dose] ? 'tablet' : nil,
          'dose_description' => band[:dose_description]
        }
      end
    end

    def age_band_label(min_months, max_months)
      if max_months.nil?
        if min_months >= 24
          '≥2 years'
        elsif min_months >= 12
          "#{min_months} months and more"
        else
          "≥#{min_months} months"
        end
      elsif min_months == 0 && max_months == 11
        '<1 year'
      elsif min_months == 12 && max_months == 23
        '1 to <2 years'
      elsif max_months < 12
        "#{min_months} to #{max_months} months"
      else
        "#{min_months / 12}-#{max_months / 12} years"
      end
    end

    # ---- Vitamin A -----------------------------------------------------

    def vitamin_a_section
      concept_name = 'Vitamin A'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Outpatient Therapeutic Services',
        'drugs' => drugs,
        'route' => 'Oral',
        'dosage_form' => 'Capsule',
        'units' => 'IU',
        'when_given' => '1 dose on the 4th week (4th visit) — all patients',
        'age_bands' => Impow::OtsDrugDosageService.all_vitamin_a_age_bands.map do |band|
          {
            'label' => age_band_label(band[:min_months], band[:max_months]),
            'min_age_months' => band[:min_months],
            'max_age_months' => band[:max_months],
            'dose_iu' => band[:dose_iu],
            'dose_description' => band[:dose_description]
          }
        end
      }
    end

    # ---- Measles-Rubella -----------------------------------------------

    def measles_rubella_section
      concept_name = 'Measles-Rubella Vaccine'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Outpatient Therapeutic Services',
        'drugs' => drugs,
        'dose' => 1,
        'dose_unit' => 'dose',
        'when_given' => '4th week (4th visit)',
        'eligibility_criteria' => 'No record of vaccination after 9 months old, OR at 6 months old during measles outbreak',
        'note' => 'Given to all eligible patients regardless of weight'
      }
    end

    # ---- NRU (Inpatient Therapeutic Service) ---------------------------

    def nru_program_section
      concept_set = ConceptName.find_by(name: 'Inpatient Therapeutic Service')

      {
        'program_name' => 'Inpatient Therapeutic Service',
        'program_code' => 'NRU',
        'concept_set_id' => concept_set&.concept_id,
        'description' => 'Inpatient treatment for severe acute malnutrition with medical complications',
        'drugs' => {
          'f75' => f75_section,
          'f100' => f100_section,
          'rutf_nru' => rutf_nru_section
        }
      }
    end

    def f75_section
      concept_name = 'Therapeutic Milk'
      concept = ConceptName.find_by(name: concept_name)
      # F-75 is a specific drug name, not just any drug with this concept
      drug = Drug.find_by(name: 'F-75 Therapeutic Milk (F75)')

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => 'F-75 Therapeutic Milk (F75)',
        'concept_set' => 'Inpatient Therapeutic Service',
        'drugs' => if drug
                     [{
                       'drug_id' => drug.drug_id,
                       'drug_name' => drug.name,
                       'strength' => extract_strength(drug.name),
                       'units' => drug.units,
                       'dosage_form' => get_dosage_form_name(drug.dosage_form),
                       'route' => get_route_name(drug.route)
                     }]
                   else
                     []
                   end,
        'description' => 'Low protein therapeutic milk for initial stabilization phase'
      }
    end

    def f100_section
      concept_name = 'Therapeutic Milk'
      concept = ConceptName.find_by(name: concept_name)
      # F-100 is a specific drug name, not just any drug with this concept
      drug = Drug.find_by(name: 'F-100 Therapeutic Milk (F100)')

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => 'F-100 Therapeutic Milk (F100)',
        'concept_set' => 'Inpatient Therapeutic Service',
        'drugs' => if drug
                     [{
                       'drug_id' => drug.drug_id,
                       'drug_name' => drug.name,
                       'strength' => extract_strength(drug.name),
                       'units' => drug.units,
                       'dosage_form' => get_dosage_form_name(drug.dosage_form),
                       'route' => get_route_name(drug.route)
                     }]
                   else
                     []
                   end,
        'description' => 'High protein therapeutic milk for transition and rehabilitation phase'
      }
    end

    def rutf_nru_section
      concept_name = 'Ready-to-Use Therapeutic Food (RUTF)'
      concept = ConceptName.find_by(name: concept_name)
      drugs = get_drugs_by_concept_name(concept_name)

      {
        'concept_id' => concept&.concept_id,
        'concept_name' => concept_name,
        'concept_set' => 'Inpatient Therapeutic Service',
        'drugs' => drugs,
        'description' => 'Used during rehabilitation phase in NRU'
      }
    end

    # ---- CouchDB Views -------------------------------------------------

    def couchdb_views
      {
        '_design/impow_drugs' => {
          'views' => {
            'rutf_by_weight' => {
              'description' => 'Emits each RUTF weight band so you can query by exact weight',
              'map' => 'function(doc) { if (doc.type === "impow_drug_reference" && doc.programs && doc.programs.ots && doc.programs.ots.drugs && doc.programs.ots.drugs.rutf) { doc.programs.ots.drugs.rutf.weight_bands.forEach(function(b) { emit([b.min_kg, b.max_kg], { sachets_per_day: b.sachets_per_day, sachets_per_week: b.sachets_per_week }); }); } }'
            },
            'amoxicillin_by_weight' => {
              'description' => 'Emits each Amoxicillin weight band',
              'map' => 'function(doc) { if (doc.type === "impow_drug_reference" && doc.programs && doc.programs.ots && doc.programs.ots.drugs && doc.programs.ots.drugs.amoxicillin) { doc.programs.ots.drugs.amoxicillin.weight_bands.forEach(function(b) { emit([b.min_kg, b.max_kg], { dose_mg: b.dose_mg, frequency: b.frequency, drug_name: b.drug_name }); }); } }'
            },
            'deworming_by_age' => {
              'description' => 'Emits each deworming age band for both drugs',
              'map' => 'function(doc) { if (doc.type === "impow_drug_reference" && doc.programs && doc.programs.ots && doc.programs.ots.drugs && doc.programs.ots.drugs.deworming) { var dw = doc.programs.ots.drugs.deworming.drugs; ["albendazole","mebendazole"].forEach(function(key) { if (dw[key] && dw[key].age_bands) { dw[key].age_bands.forEach(function(b) { emit([key, b.min_age_months, b.max_age_months], { dose: b.dose, dose_description: b.dose_description }); }); } }); } }'
            },
            'vitamin_a_by_age' => {
              'description' => 'Emits Vitamin A doses by age band',
              'map' => 'function(doc) { if (doc.type === "impow_drug_reference" && doc.programs && doc.programs.ots && doc.programs.ots.drugs && doc.programs.ots.drugs.vitamin_a) { doc.programs.ots.drugs.vitamin_a.age_bands.forEach(function(b) { emit([b.min_age_months, b.max_age_months], { dose_iu: b.dose_iu, dose_description: b.dose_description }); }); } }'
            },
            'drugs_by_program' => {
              'description' => 'Emits all drugs grouped by program (SFP, OTS, NRU)',
              'map' => 'function(doc) { if (doc.type === "impow_drug_reference" && doc.programs) { for (var program in doc.programs) { emit(program, { program_name: doc.programs[program].program_name, drug_count: Object.keys(doc.programs[program].drugs || {}).length }); } } }'
            }
          }
        }
      }
    end
  end
end

# Usage:
# Sync::ImpowDrugSyncJob.perform_async
# rails "sync:run[ImpowDrugSyncJob]"
