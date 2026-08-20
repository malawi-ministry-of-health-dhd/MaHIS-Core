# frozen_string_literal: true

module ArtService
  ##
  # Batch preloads viral load lab orders/results for a set of patients in a
  # handful of queries instead of ArtService::VlReminder and
  # ArtService::Reports::ViralLoad each issuing their own SQL per patient
  # (this backs the "Clients due for viral load" report, which can process
  # hundreds of patients per request).
  class VlBatchLoader
    RECENT_SPECIMEN_NAMES = ['Blood', 'DBS (Free drop to DBS card)', 'DBS (Using capillary tube)', 'Plasma'].freeze
    LAST_SPECIMEN_NAMES = ['Blood', 'DBS (Free drop to DBS card)', 'DBS (Using capillary tube)'].freeze

    def initialize(patient_ids:, start_date:, end_date:)
      @patient_ids = patient_ids.map(&:to_i)
      @start_date = start_date.to_date
      @end_date = end_date.to_date
      @recent_orders = {}
      @last_orders = {}
      @last_vl_results = {}
      preload
    end

    # Mirrors ArtService::VlReminder#find_patient_recent_viral_load
    def recent_viral_load(patient_id, date, duration)
      window_start = date - duration
      (@recent_orders[patient_id] || [])
        .select { |order| order.start_date.to_date.between?(window_start, date) }
        .max_by(&:start_date)
    end

    # Mirrors ArtService::VlReminder#find_patient_last_viral_load
    def last_viral_load(patient_id, date)
      (@last_orders[patient_id] || [])
        .select { |order| order.start_date.to_date <= date }
        .max_by(&:start_date)
    end

    # Mirrors ArtService::Reports::ViralLoad#last_vl_result
    def last_vl_result(patient_id)
      (@last_vl_results[patient_id] || []).first
    end

    private

    def preload
      return if @patient_ids.blank?

      preload_viral_load_orders
      preload_last_vl_results
    end

    def viral_load_tests
      Observation.where(concept: ConceptName.where(name: 'Test type').select(:concept_id),
                        value_coded: ConceptName.where(name: 'Viral Load').select(:concept_id))
    end

    def preload_viral_load_orders
      # 12 months is the only duration ever used for the "recent" lookup, so a
      # single lookback bound covers every patient in the batch.
      lookback_start = @start_date - 12.months

      recent_specimens = ConceptName.where(name: RECENT_SPECIMEN_NAMES).select(:concept_id)
      @recent_orders = Lab::LabOrder.where(concept: recent_specimens, patient_id: @patient_ids)
                                    .where('start_date BETWEEN DATE(?) AND DATE(?)', lookback_start, @end_date)
                                    .joins(:tests)
                                    .merge(viral_load_tests)
                                    .group_by(&:patient_id)

      last_specimens = ConceptName.where(name: LAST_SPECIMEN_NAMES).select(:concept_id)
      @last_orders = Lab::LabOrder.where(concept: last_specimens, patient_id: @patient_ids)
                                  .where('start_date <= DATE(?)', @end_date)
                                  .joins(:tests)
                                  .merge(viral_load_tests)
                                  .group_by(&:patient_id)
    end

    def preload_last_vl_results
      viral_load_concept = ConceptName.where(name: 'HIV Viral Load').select(:concept_id)
      result_sql = <<~SQL
        INNER JOIN obs AS parent
          ON parent.obs_id = obs.obs_group_id
          AND parent.concept_id IN (SELECT concept_id FROM concept_name WHERE name = 'Lab test result' AND voided = 0)
          AND parent.voided = 0
          AND parent.person_id = obs.person_id
      SQL

      @last_vl_results = Observation.joins(result_sql)
                                    .where(concept: viral_load_concept, person_id: @patient_ids)
                                    .where('(obs.value_numeric IS NOT NULL OR obs.value_text IS NOT NULL)
                                        AND obs.obs_datetime < DATE(?) + INTERVAL 1 DAY', @end_date)
                                    .order(obs_datetime: :desc)
                                    .group_by(&:person_id)
    end
  end
end
