# frozen_string_literal: true

require 'rest-client'
require 'json'

module NcdService
  module Reports
    class CouchDashboard
      PATIENT_FIELDS = %w[
        patientID
        ncd_active
        ncd_location_id
        ncd_gender
        ncd_pending_id
        ncd_has_pending_dispensation
        ncd_has_complications
        ncd_last_dispensation_date
        ncd_last_visit_date
        ncd_latest_primary_diagnosis
        ncd_observation_quarters
        ncd_diagnosis_quarters
        personInformation
      ].freeze

      PENDING_PATIENT_FIELDS = %w[
        patientID
        ncd_pending_id
        ncd_last_visit_date
        personInformation
      ].freeze

      STATS_PATIENT_FIELDS = %w[
        ncd_gender
        ncd_has_complications
        ncd_has_pending_dispensation
        ncd_last_dispensation_date
      ].freeze

      PAGE_SIZE = 10_000
      PENDING_PREVIEW_LIMIT = 5
      STATS_VIEW = NcdService::NcdPatientIndex::STATS_VIEW

      def self.find_report(start_date:, end_date:, **extra_kwargs)
        new.find_report(
          start_date: start_date,
          end_date: end_date,
          sections: extra_kwargs[:sections],
          **extra_kwargs.except(:sections)
        )
      end

      def self.available?(location_id: nil)
        return false unless CouchdbPatientService.couchdb_configured?

        ensure_indexes!
        selector = { ncd_active: true }
        selector[:ncd_location_id] = location_id.to_s if location_id.present?
        result = query(selector: selector, limit: 1, fields: %w[patientID], use_index: 'idx_ncd_location_active')
        result.fetch('docs', []).any?
      rescue StandardError => e
        Rails.logger.warn("[NCD CouchDashboard] unavailable: #{e.class}: #{e.message}")
        false
      end

      # The dashboard now reads from the dedicated ncd_patient_index database
      # (one compact projection per NCD patient) rather than scanning the large
      # patients_records documents. Index/view setup and querying are delegated
      # to NcdService::NcdPatientIndex.
      def self.ensure_indexes!
        NcdService::NcdPatientIndex.ensure!
      end

      def self.query(selector:, limit:, fields:, bookmark: nil, use_index: nil)
        NcdService::NcdPatientIndex.query(
          selector: selector,
          limit: limit,
          fields: fields,
          bookmark: bookmark,
          use_index: use_index
        )
      end

      def self.view(view_name, params = {})
        NcdService::NcdPatientIndex.view(view_name, params)
      end

      def find_report(start_date:, end_date:, sections: nil, **kwargs)
        @start_date = start_date
        @end_date = end_date
        @sections = normalize_sections(sections)
        @location_id = (kwargs[:location_id] || User.current&.location_id).presence&.to_s

        return nil unless self.class.available?(location_id: @location_id)

        @patient_fields = patient_fields_for_sections
        @patients = fetch_ncd_patients if patient_scan_required?
        return nil if patient_scan_required? && @patients.blank?

        data(sections: @sections)
      rescue StandardError => e
        Rails.logger.warn("[NCD CouchDashboard] falling back to MySQL: #{e.class}: #{e.message}")
        nil
      end

      private

      def normalize_sections(sections)
        sections = ['all'] if sections.blank?
        sections = [sections] if sections.is_a?(String)
        sections
      end

      def patient_scan_required?
        @patient_scan_required ||= begin
          all_sections = @sections.blank? || @sections.include?('all')
          all_sections || (@sections & %w[defaulters top_conditions gender_chart diagnosis_chart]).any?
        end
      end

      def patient_fields_for_sections
        return PATIENT_FIELDS if @sections.blank? || @sections.include?('all')

        fields = []
        fields.concat(STATS_PATIENT_FIELDS) if @sections.include?('stats')
        fields.concat(%w[patientID ncd_last_dispensation_date personInformation]) if @sections.include?('defaulters')
        fields.concat(%w[ncd_latest_primary_diagnosis]) if @sections.include?('top_conditions')
        fields.concat(%w[ncd_gender ncd_observation_quarters]) if @sections.include?('gender_chart')
        fields.concat(%w[ncd_diagnosis_quarters]) if @sections.include?('diagnosis_chart')
        fields.presence || PATIENT_FIELDS
      end

      def fetch_ncd_patients
        selector = { ncd_active: true }
        selector[:ncd_location_id] = @location_id if @location_id.present?

        patients = []
        bookmark = nil

        loop do
          result = self.class.query(
            selector: selector,
            limit: PAGE_SIZE,
            fields: @patient_fields,
            bookmark: bookmark,
            use_index: 'idx_ncd_location_active'
          )
          docs = result.fetch('docs', [])
          patients.concat(docs)
          break if docs.length < PAGE_SIZE

          next_bookmark = result['bookmark']
          break if next_bookmark.blank? || next_bookmark == bookmark

          bookmark = next_bookmark
        end

        patients
      end

      def data(sections:)
        res = {}
        all_sections = sections.blank? || sections.include?('all')

        if all_sections || sections.include?('stats')
          res.merge!(stats_data)
        end

        if all_sections || sections.include?('pending_ncd')
          pending = pending_ncd_data
          res.merge!(
            total_pending_ncd_numbers: pending[:count],
            pending_ncd_patients: pending[:patients]
          )
        end

        res[:defaulter_alerts] = defaulters.first(5) if all_sections || sections.include?('defaulters')
        res[:top_conditions] = top_conditions if all_sections || sections.include?('top_conditions')
        res[:gender_data] = gender_data if all_sections || sections.include?('gender_chart')
        res[:diagnosis_data] = diagnosis_data if all_sections || sections.include?('diagnosis_chart')

        res
      end

      def pending_ncd_data
        if @patients.present?
          pending_count = 0
          preview = []

          @patients.each do |patient|
            next unless patient['ncd_pending_id'] == true

            pending_count += 1
            preview << pending_patient_row(patient) if preview.length < PENDING_PREVIEW_LIMIT
          end

          return { count: pending_count, patients: preview }
        end

        pending_ncd_data_from_couch
      end

      def pending_ncd_data_from_couch
        selector = { ncd_active: true, ncd_pending_id: true }
        selector[:ncd_location_id] = @location_id if @location_id.present?

        result = self.class.query(
          selector: selector,
          limit: PENDING_PREVIEW_LIMIT,
          fields: PENDING_PATIENT_FIELDS,
          use_index: 'idx_ncd_location_pending_id'
        )

        { count: pending_count_from_view, patients: result.fetch('docs', []).map { |patient| pending_patient_row(patient) } }
      end

      def pending_patient_row(patient)
          {
            id: patient['patientID'],
            name: patient_name(patient),
            date: patient['ncd_last_visit_date']
          }
      end

      def stats_data
        return stats_data_from_patients if @patients.present?

        stats_data_from_view
      end

      def stats_data_from_patients
        {
          total_client_registered: @patients.length,
          total_male_registered: @patients.count { |patient| patient['ncd_gender'] == 'M' },
          total_female_registered: @patients.count { |patient| patient['ncd_gender'] == 'F' },
          total_complications: @patients.count { |patient| patient['ncd_has_complications'] == true },
          total_defaulters: defaulters.length,
          total_pending_dispensations: @patients.count { |patient| patient['ncd_has_pending_dispensation'] == true }
        }
      end

      def stats_data_from_view
        rows = self.class.view(
          STATS_VIEW,
          group: true,
          startkey: [@location_id, nil].to_json,
          endkey: [@location_id, {}].to_json
        ).fetch('rows', [])

        counters = Hash.new(0)
        rows.each do |row|
          key = row['key']
          metric = key[1]
          case metric
          when 'total'
            counters[:total_client_registered] += row['value'].to_i
          when 'gender'
            counters[key[2] == 'M' ? :total_male_registered : :total_female_registered] += row['value'].to_i
          when 'complications'
            counters[:total_complications] += row['value'].to_i
          when 'pending_dispensation'
            counters[:total_pending_dispensations] += row['value'].to_i
          end
        end

        counters[:total_defaulters] = defaulter_count_from_view
        {
          total_client_registered: counters[:total_client_registered],
          total_male_registered: counters[:total_male_registered],
          total_female_registered: counters[:total_female_registered],
          total_complications: counters[:total_complications],
          total_defaulters: counters[:total_defaulters],
          total_pending_dispensations: counters[:total_pending_dispensations]
        }
      end

      def defaulter_count_from_view
        cutoff = Date.current - 60.days
        cutoff_120 = Date.current - 120.days
        result = self.class.view(
          STATS_VIEW,
          reduce: true,
          startkey: [@location_id, 'last_dispensation', cutoff_120.to_s].to_json,
          endkey: [@location_id, 'last_dispensation', cutoff.to_s].to_json
        )
        result.fetch('rows', []).first&.fetch('value', 0).to_i
      end

      def pending_count_from_view
        result = self.class.view(
          STATS_VIEW,
          reduce: true,
          startkey: [@location_id, 'pending_id'].to_json,
          endkey: [@location_id, 'pending_id'].to_json
        )
        result.fetch('rows', []).first&.fetch('value', 0).to_i
      end

      def defaulters
        cutoff = Date.current - 60.days
        cutoff_120 = Date.current - 120.days

        @patients.filter_map do |patient|
          last_date = parse_date(patient['ncd_last_dispensation_date'])
          next unless last_date && last_date >= cutoff_120 && last_date <= cutoff

          {
            id: patient['patientID'],
            name: patient_name(patient),
            missedCount: 1,
            timeAgo: "#{(Date.current - last_date).to_i} days ago"
          }
        end.sort_by { |item| item[:timeAgo].to_i }
      end

      def top_conditions
        counts = diagnosis_counts(@patients.filter_map { |patient| patient['ncd_latest_primary_diagnosis'] })
        total = counts.values.sum
        return [] if total.zero?

        [
          condition_row('Type 2 Diabetes', counts[:type2], total),
          condition_row('Hypertension', counts[:hypertension], total),
          condition_row('Type 1 Diabetes', counts[:type1], total),
          condition_row('Other NCDs', counts[:other], total)
        ].sort_by { |condition| -condition[:count] }
      end

      def gender_data
        quarters = recent_quarters.each_with_object({}) do |quarter, memo|
          memo[quarter] = { male: 0, female: 0 }
        end

        @patients.each do |patient|
          Array(patient['ncd_observation_quarters']).each do |quarter|
            next unless quarters.key?(quarter)

            if patient['ncd_gender'] == 'M'
              quarters[quarter][:male] += 1
            elsif patient['ncd_gender'] == 'F'
              quarters[quarter][:female] += 1
            end
          end
        end

        {
          categories: quarters.keys,
          series: [
            { name: 'Male', data: quarters.values.map { |quarter| quarter[:male] }, group: 'apexcharts-axis-0' },
            { name: 'Female', data: quarters.values.map { |quarter| quarter[:female] }, group: 'apexcharts-axis-0' }
          ]
        }
      end

      def diagnosis_data
        quarters = recent_quarters.each_with_object({}) do |quarter, memo|
          memo[quarter] = { type_one: 0, type_two: 0, hypertension: 0 }
        end

        @patients.each do |patient|
          Hash(patient['ncd_diagnosis_quarters']).each do |quarter, value|
            next unless quarters.key?(quarter)

            bucket = diagnosis_bucket(value)
            next unless bucket && quarters[quarter].key?(bucket)

            quarters[quarter][bucket] += 1
          end
        end

        {
          categories: quarters.keys,
          series: [
            { name: 'Type 1 Diabetes', data: quarters.values.map { |quarter| quarter[:type_one] }, group: 'apexcharts-axis-0' },
            { name: 'Type 2 Diabetes', data: quarters.values.map { |quarter| quarter[:type_two] }, group: 'apexcharts-axis-0' },
            { name: 'Hypertension', data: quarters.values.map { |quarter| quarter[:hypertension] }, group: 'apexcharts-axis-0' }
          ]
        }
      end

      def condition_row(name, count, total)
        { name: name, count: count, percent: ((count.to_f / total) * 100).round }
      end

      def diagnosis_counts(values)
        values.each_with_object({ type1: 0, type2: 0, hypertension: 0, other: 0 }) do |value, counts|
          bucket = diagnosis_bucket(value)
          counts[bucket || :other] += 1
        end
      end

      def diagnosis_bucket(value)
        value = value.to_i
        return :type1 if value == concept_id('Type 1 diabetes mellitus')
        return :type2 if value == concept_id('Type 2 diabetes mellitus')
        return :hypertension if value == concept_id('Hypertension') || value == 903

        nil
      end

      def concept_id(name)
        @concept_ids ||= {}
        @concept_ids[name] ||= ConceptName.find_by_name(name)&.concept_id.to_i
      end

      def recent_quarters
        quarters = []
        date = Date.current
        4.times do
          start = date.beginning_of_quarter
          quarters << format_quarter_label(start)
          date = start - 1.day
        end
        quarters.reverse
      end

      def format_quarter_label(date)
        "Q#{((date.month - 1) / 3) + 1} #{date.year}"
      end

      def patient_name(patient)
        info = patient['personInformation'] || {}
        [info['given_name'], info['family_name']].compact_blank.join(' ').presence || 'Unknown Patient'
      end

      def parse_date(value)
        return value if value.is_a?(Date)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
