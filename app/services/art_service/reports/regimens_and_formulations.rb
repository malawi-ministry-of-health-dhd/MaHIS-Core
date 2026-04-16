# frozen_string_literal: true

module ArtService
  module Reports
    # Retrieve patients in a particular regimen and formulation.
    class RegimensAndFormulations
      include CommonSqlQueryUtils

      attr_reader :start_date, :end_date, :regimen, :formulation, :location_id

      def initialize(start_date:, end_date:, regimen: nil, formulation: 'tablets', **kwargs)
        raise InvalidParameterError, 'regimen is required' unless regimen

        unless %w[granules tablets pellets].include?(formulation)
          raise InvalidParameterError, "Invalid formalation: #{formulation}"
        end

        @start_date = start_date.to_date
        @end_date = end_date.to_date
        @formulation = formulation
        @regimen = regimen
        @occupation = kwargs[:occupation]
        @dsd = kwargs[:dsd]
        @location_id = Location.current.location_id
      end

      def find_report
        patients
      end

      def patients
        patients_with_prescriptions.each_with_object([]) do |patient, matching_patients|
          prescribed_drugs = drugs_prescribed_to_patient(patient.patient_id, patient.prescription_date).map(&:drug_id)
          non_matching_drugs = Set.new(drugs) - prescribed_drugs

          next unless non_matching_drugs.empty?

          demographics = patient_demographics(patient.patient_id, patient.prescription_date)

          matching_patients << {
            patient_id: demographics.patient_id,
            arv_number: demographics.arv_number,
            birthdate: demographics.birthdate,
            gender: demographics.gender,
            weight: demographics.weight,
            drugs: regimen_drugs(prescribed_drugs),
            regimen:
          }
        end
      end

      private

      TABLET_REGIMENS = {
        '0A' => [809, 16],
        '0P' => [882, 808],
        '2A' => [573],
        '2P' => [574],
        '4A' => [33, 7],
        '4P' => [578, 24],
        '5A' => [577],
        '6A' => [576, 16],
        '7A' => [576, 772],
        '8A' => [33, 772],
        '9A' => [809, 66],
        '9P' => [882, 66],
        '10A' => [576, 66],
        '11A' => [33, 66],
        '11P' => [578, 66],
        '12A' => [822, 817, 816],
        '13A' => [823],
        '14A' => [824, 822],
        '14P' => [578, 822],
        '15A' => [809, 822],
        '15P' => [1170],
        '16A' => [809, 794],
        '16P' => [882, 881],
        '17A' => [809, 7],
        '17P' => [882, 24]
      }.freeze

      GRANULES_REGIMENS = {
        '9P' => [882, 883],
        '11P' => [578, 883]
      }.freeze

      PELLETS_REGIMENS = {
        '9P' => [882, 819],
        '11P' => [578, 819]
      }.freeze

      REGIMENS_BY_FORMULATION = {
        'granules' => GRANULES_REGIMENS,
        'pellets' => PELLETS_REGIMENS,
        'tablets' => TABLET_REGIMENS
      }.freeze

      # Returns drugs in selected regimen and formulation
      def drugs
        REGIMENS_BY_FORMULATION[formulation][regimen]
      end

      def patients_with_prescriptions
        return [] if drugs.nil?

        d_orders = DrugOrder.select('orders.patient_id AS patient_id, MAX(orders.start_date) AS prescription_date')
                 .joins(:order)
                 .joins("LEFT JOIN (#{current_occupation_query}) AS a ON a.person_id = orders.patient_id")
                 .where(quantity: 1..Float::INFINITY, drug_inventory_id: drugs)
                 .where(occupation_filter(occupation: @occupation, field_name: 'value', table_name: 'a',
                                          include_clause: false).to_s)
                 .merge(treatment_orders)
                 .group('orders.patient_id')
        d_orders = d_orders.joins(dsd_query(dsd: @dsd, model: 'orders')) if @dsd
        d_orders
      end

      # Returns all orders in treatment encounter of HIV program
      def treatment_orders
        Order.joins(:encounter)
             .where(start_date: (start_date - 1.day)..(end_date + 1.day))
             .merge(treatment_encounter)
             .or(Order.joins(:encounter)
                      .where(auto_expire_date: start_date..end_date)
                      .merge(treatment_encounter))
             .or(Order.joins(:encounter)
                      .where('orders.start_date < ? AND auto_expire_date > ?', start_date, end_date)
                      .merge(treatment_encounter))
      end

      def treatment_encounter
        Encounter.where(encounter_type: EncounterType.find_by_name('Treatment'),
                        program_id: Constants::PROGRAM_ID,
                        location_id:)
      end

      # Returns drugs prescribed to patient on given day
      def drugs_prescribed_to_patient(patient_id, prescription_date)
        DrugOrder.select('drug_order.drug_inventory_id AS drug_id')
                 .joins(:order)
                 .where(quantity: 1..Float::INFINITY, drug_inventory_id: drugs)
                 .merge(Order.joins(:encounter)
                             .where(patient_id:, start_date: prescription_date)
                             .merge(treatment_encounter))
      end

      def patient_demographics(patient_id, prescription_date)
        Person.find_by_sql(
          <<~SQL
            SELECT person.person_id AS patient_id, patient_identifier.identifier AS arv_number,
                   person.birthdate AS birthdate, person.gender AS gender, obs.value_numeric AS weight
            FROM person
            LEFT JOIN patient_identifier ON patient_identifier.patient_id = person.person_id
                                         AND patient_identifier.identifier_type = #{arv_number_type_id}
                                         AND patient_identifier.voided = 0
            LEFT JOIN obs ON obs.person_id = person.person_id
                          AND obs.concept_id = #{weight_concept_id}
                          AND obs.location_id = #{location_id}
                          AND obs.obs_datetime = (
                            SELECT MAX(obs_datetime) FROM obs
                            WHERE person_id = #{patient_id}
                              AND concept_id = #{weight_concept_id}
                              AND location_id = #{location_id}
                              AND obs_datetime <= '#{prescription_date}'
                              AND voided = 0
                          ) AND obs.voided = 0
            WHERE person.person_id = #{patient_id}
          SQL
        ).first
      end

      def patient_recent_weight(patient_id, as_of)
        Observation.select(:value_numeric)
                   .where(concept_id: ConceptName.find_by_name('Weight (kg)').concept_id,
                          person_id: patient_id,
                          location_id:)
                   .where('obs_datetime < ? AND value_numeric IS NOT NULL', as_of)
                   .order(obs_datetime: :desc)
                   .first
                   &.value_numeric
      end

      def regimen_drugs(drug_ids = [578, 822])
        @regimen_drugs ||= Drug.where(drug_id: drug_ids).map do |drug|
          drug.alternative_names.first&.short_name || drug.name
        end.join(' + ')
      end

      def weight_concept_id
        @weight_concept_id ||= ConceptName.find_by_name('Weight (kg)').concept_id
      end

      def arv_number_type_id
        @arv_number_type_id ||= PatientIdentifierType.find_by_name('ARV Number').id
      end
    end
  end
end
