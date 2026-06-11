# frozen_string_literal: true

module Impow
  # Service for OTS (Outpatient Therapeutic Services) drug dosage calculations
  # and lookups. Used by OtsDrugSyncJob and can be used by controllers/services
  # that need to calculate dosages for RUTF, Amoxicillin, Deworming, and Vitamin A.
  class OtsDrugDosageService
    # ----------------------------------------------------------------
    # RUTF lookup by patient weight (kg)
    # Returns { sachets_per_day:, sachets_per_week: } or nil
    # ----------------------------------------------------------------
    RUTF_WEIGHT_BANDS = [
      { min: 3.0,  max: 3.4,  day: 1.0, week: 7  },
      { min: 3.5,  max: 3.9,  day: 1.0, week: 7  },
      { min: 4.0,  max: 4.4,  day: 1.5, week: 11 },
      { min: 4.5,  max: 4.9,  day: 1.5, week: 11 },
      { min: 5.0,  max: 5.4,  day: 2.0, week: 14 },
      { min: 5.5,  max: 5.9,  day: 2.0, week: 14 },
      { min: 6.0,  max: 6.4,  day: 2.0, week: 14 },
      { min: 6.5,  max: 6.9,  day: 2.0, week: 14 },
      { min: 7.0,  max: 7.4,  day: 2.5, week: 18 },
      { min: 7.5,  max: 7.9,  day: 2.5, week: 18 },
      { min: 8.0,  max: 8.4,  day: 3.0, week: 21 },
      { min: 8.5,  max: 8.9,  day: 3.0, week: 21 },
      { min: 9.0,  max: 9.4,  day: 3.0, week: 21 },
      { min: 9.5,  max: 9.9,  day: 3.0, week: 21 },
      { min: 10.0, max: 10.4, day: 3.5, week: 25 },
      { min: 10.5, max: 10.9, day: 3.5, week: 25 },
      { min: 11.0, max: 11.4, day: 4.0, week: 28 },
      { min: 11.5, max: 11.9, day: 4.0, week: 28 },
      { min: 12.0, max: 12.4, day: 4.0, week: 28 },
      { min: 12.5, max: 12.9, day: 4.0, week: 28 },
      { min: 13.0, max: 13.4, day: 4.5, week: 32 },
      { min: 13.5, max: 13.9, day: 4.5, week: 32 },
      { min: 14.0, max: Float::INFINITY, day: 5.0, week: 35 }
    ].freeze

    def self.rutf_dose_for_weight(weight_kg)
      band = RUTF_WEIGHT_BANDS.find { |b| weight_kg >= b[:min] && weight_kg <= b[:max] }
      return nil unless band

      { sachets_per_day: band[:day], sachets_per_week: band[:week] }
    end

    # ----------------------------------------------------------------
    # Amoxicillin lookup by patient weight (kg)
    # Returns { dose_mg:, frequency:, drug_name: } or nil
    # ----------------------------------------------------------------
    AMOXICILLIN_WEIGHT_BANDS = [
      { min: 0,    max: 4.9,  dose_mg: 125,  drug_name: 'Amoxicillin (125mg tablet)' },
      { min: 5.0,  max: 10.0, dose_mg: 250,  drug_name: 'Amoxicillin (250mg tablet)' },
      { min: 10.0, max: 20.0, dose_mg: 500,  drug_name: 'Amoxicillin (500mg tablet)' },
      { min: 20.0, max: 35.0, dose_mg: 750,  drug_name: 'Amoxicillin (750mg tablet)' },
      { min: 35.0, max: Float::INFINITY, dose_mg: 1000, drug_name: 'Amoxicillin (1000mg tablet)' }
    ].freeze

    AMPICILLIN_WEIGHT_BANDS = [
      { min: 0,    max: 4.9,  dose_mg: 125,  drug_name: 'Ampicillin (125mg tablet)' },
      { min: 5.0,  max: 10.0, dose_mg: 250,  drug_name: 'Ampicillin (250mg tablet)' },
      { min: 10.0, max: 20.0, dose_mg: 500,  drug_name: 'Ampicillin (500mg tablet)' },
      { min: 20.0, max: 35.0, dose_mg: 750,  drug_name: 'Ampicillin (750mg tablet)' },
      { min: 35.0, max: Float::INFINITY, dose_mg: 1000, drug_name: 'Ampicillin (1000mg tablet)' }
    ].freeze

    def self.amoxicillin_dose_for_weight(weight_kg)
      band = AMOXICILLIN_WEIGHT_BANDS.find { |b| weight_kg >= b[:min] && weight_kg <= b[:max] }
      return nil unless band

      { dose_mg: band[:dose_mg], frequency: 'twice daily', drug_name: band[:drug_name] }
    end

    # ----------------------------------------------------------------
    # Deworming dose by age in months
    # drug_key: :albendazole or :mebendazole
    # Returns { dose:, dose_description:, drug_name: } or nil
    # ----------------------------------------------------------------
    DEWORMING_AGE_BANDS = {
      albendazole: [
        { min_months: 0,  max_months: 11,  dose: nil, dose_description: 'Not given',  drug_name: 'Albendazole 400mg' },
        { min_months: 12, max_months: 23,  dose: 0.5, dose_description: '½ tablet',   drug_name: 'Albendazole 400mg' },
        { min_months: 24, max_months: nil, dose: 1,   dose_description: '1 tablet',   drug_name: 'Albendazole 400mg' }
      ],
      mebendazole: [
        { min_months: 0,  max_months: 11,  dose: nil, dose_description: 'Not given',  drug_name: 'Mebendazole 500mg' },
        { min_months: 12, max_months: 23,  dose: 0.5, dose_description: '½ tablet',   drug_name: 'Mebendazole 500mg' },
        { min_months: 24, max_months: nil, dose: 1,   dose_description: '1 tablet',   drug_name: 'Mebendazole 500mg' }
      ]
    }.freeze

    def self.deworming_dose_for_age(age_months, drug_key: :albendazole)
      bands = DEWORMING_AGE_BANDS[drug_key]
      return nil unless bands

      band = bands.find { |b| age_months >= b[:min_months] && (b[:max_months].nil? || age_months <= b[:max_months]) }
      return nil unless band

      { dose: band[:dose], dose_description: band[:dose_description], drug_name: band[:drug_name] }
    end

    # ----------------------------------------------------------------
    # Vitamin A dose by age in months
    # Returns { dose_iu:, dose_description: } or nil
    # ----------------------------------------------------------------
    VITAMIN_A_AGE_BANDS = [
      { min_months: 6,  max_months: 11,  dose_iu: 100_000, dose_description: '100,000 IU' },
      { min_months: 12, max_months: nil, dose_iu: 200_000, dose_description: '200,000 IU' }
    ].freeze

    def self.vitamin_a_dose_for_age(age_months)
      band = VITAMIN_A_AGE_BANDS.find do |b|
        age_months >= b[:min_months] && (b[:max_months].nil? || age_months <= b[:max_months])
      end
      band ? { dose_iu: band[:dose_iu], dose_description: band[:dose_description] } : nil
    end

    # ----------------------------------------------------------------
    # Helper methods to get all weight bands (for sync job)
    # ----------------------------------------------------------------

    def self.all_rutf_weight_bands
      RUTF_WEIGHT_BANDS
    end

    def self.all_amoxicillin_weight_bands
      AMOXICILLIN_WEIGHT_BANDS
    end

    def self.all_ampicillin_weight_bands
      AMPICILLIN_WEIGHT_BANDS
    end

    def self.all_deworming_age_bands
      DEWORMING_AGE_BANDS
    end

    def self.all_vitamin_a_age_bands
      VITAMIN_A_AGE_BANDS
    end
  end
end
