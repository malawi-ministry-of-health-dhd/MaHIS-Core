# frozen_string_literal: true

module NcdService
  # Drill-down patient list for the NCD dashboard, served from the
  # ncd_patient_index CouchDB database instead of the heavy MySQL cohort query.
  #
  # Filtering + pagination run against the index (one Mango query over the
  # location's NCD subset); display detail comes from the same compact
  # projections. The response shape mirrors NcdActivePatientService / the
  # frontend offline mapper, so no frontend change is required. Returns nil when
  # the index is unavailable or unpopulated, so the controller can fall back to
  # the MySQL service.
  class ActivePatientsReport
    MAX_MATCH = 20_000
    DEFAULT_PER_PAGE = 10

    def self.call(location_id:, filters:)
      return nil unless NcdService::NcdPatientIndex.configured?

      new(location_id, filters).call
    rescue StandardError => e
      Rails.logger.warn("[NCD ActivePatientsReport] falling back to MySQL: #{e.class}: #{e.message}")
      nil
    end

    def initialize(location_id, filters)
      @location_id = location_id.presence&.to_s
      @filters = (filters || {}).symbolize_keys
    end

    def call
      secondary_filters? ? mango_filtered : view_paginated
    end

    private

    # Hot path: pure category navigation. The patient_list view gives an ordered
    # page and an O(1) reduce count without scanning the whole location.
    def view_paginated
      result = NcdService::NcdPatientIndex.list_by_category(
        location_id: @location_id,
        category: @filters[:category],
        gender: @filters[:gender],
        offset: offset,
        limit: per_page
      )

      return empty_or_fallback if result[:count].zero? && result[:docs].empty?

      { count: result[:count], results: result[:docs].map { |doc| map_result(doc) } }
    end

    # Filtered path (name/gender/birthdate/last-visit): Mango over the location's
    # NCD subset. Capped so a pathological location can't run unbounded.
    def mango_filtered
      matches = NcdService::NcdPatientIndex.query(
        selector: selector,
        limit: MAX_MATCH,
        fields: %w[patientID ncd_last_visit_date],
        use_index: 'idx_ncd_location_active'
      ).fetch('docs', [])

      return empty_or_fallback if matches.empty?

      sorted = matches.sort_by { |doc| doc['ncd_last_visit_date'].to_s }.reverse
      page_ids = sorted[offset, per_page]&.map { |doc| doc['patientID'] } || []
      docs = NcdService::NcdPatientIndex.fetch_by_ids(page_ids)

      { count: sorted.length, results: docs.map { |doc| map_result(doc) } }
    end

    # gender is now served by the view (composite category key), so it no longer
    # forces the Mango scan. Only name/birthdate/last-visit do.
    def secondary_filters?
      @filters[:given_name].present? || @filters[:family_name].present? ||
        @filters[:birthdate].present? || @filters[:last_visited_after].present?
    end

    def page
      value = @filters[:page].to_i
      value.positive? ? value : 1
    end

    def per_page
      value = @filters[:per_page].to_i
      value.positive? ? value : DEFAULT_PER_PAGE
    end

    def offset
      (page - 1) * per_page
    end

    def selector
      selector = { 'ncd_active' => true }
      selector['ncd_location_id'] = @location_id if @location_id.present?
      selector.merge!(category_selector(@filters[:category]))
      selector['ncd_gender'] = @filters[:gender].to_s.upcase if @filters[:gender].present?
      selector['ncd_last_visit_date'] = { '$gte' => @filters[:last_visited_after].to_s } if @filters[:last_visited_after].present?
      selector['personInformation.birthdate'] = @filters[:birthdate].to_s if @filters[:birthdate].present?
      add_name_filter!(selector, 'personInformation.given_name', @filters[:given_name])
      add_name_filter!(selector, 'personInformation.family_name', @filters[:family_name])
      selector
    end

    def category_selector(category)
      case category.to_s
      when 'complications'         then { 'ncd_has_complications' => true }
      when 'pending_dispensations' then { 'ncd_has_pending_dispensation' => true }
      when 'pending_ids'           then { 'ncd_pending_id' => true }
      when 'defaulters'
        {
          'ncd_last_dispensation_date' => {
            '$gte' => (Date.current - 120).to_s,
            '$lte' => (Date.current - 60).to_s
          }
        }
      else
        {}
      end
    end

    def add_name_filter!(selector, field, value)
      return if value.blank?

      selector[field] = { '$regex' => "(?i)#{Regexp.escape(value.to_s)}" }
    end

    # Distinguish "this location has no matches" (return an empty page) from
    # "the index is not populated yet" (return nil so the caller uses MySQL).
    def empty_or_fallback
      populated = NcdService::NcdPatientIndex.query(
        selector: { 'ncd_active' => true },
        limit: 1,
        fields: %w[patientID]
      ).fetch('docs', []).any?

      populated ? { count: 0, results: [] } : nil
    end

    def map_result(doc)
      info = doc['personInformation'] || {}
      {
        patient_id: doc['patientID'],
        encounter_datetime: doc['ncd_last_visit_date'],
        location_id: doc['ncd_location_id'],
        person: {
          gender: doc['ncd_gender'],
          birthdate: info['birthdate'],
          names: [{ given_name: info['given_name'], family_name: info['family_name'] }],
          addresses: [{ city_village: info['current_village'], state_province: info['current_district'] }],
          person_attributes: [
            { type: { name: 'Civil Status' }, value: info['marital_status'].presence || 'N/A' },
            { type: { name: 'Occupation' }, value: info['occupation'].presence || 'N/A' },
            { type: { name: 'EDUCATION LEVEL' }, value: info['education_level'].presence || 'N/A' },
            { type: { name: 'Religion' }, value: info['religion'].presence || 'N/A' }
          ]
        },
        patient_identifiers: [
          {
            patient_identifier_id: "#{doc['patientID']}_ncd",
            identifier: doc['NcdID'].presence || 'PENDING',
            type: { name: 'NCD Number' }
          }
        ]
      }
    end
  end
end
