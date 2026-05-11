require 'cgi'
require 'uri'

module Api
  module V1
    class FhirController < ApplicationController
      APP_CONFIG = YAML.safe_load(File.read('config/application.yml'))
      BASE_FHIR_URL = APP_CONFIG['BASE_FHIR_URL'] # change to your HAPI FHIR URL
      BASE_MEDIATOR_URL = APP_CONFIG['BASE_MEDIATOR_URL']

      SYNC_STATUS_TAG = 'ichis-mahis-pending'.freeze
      IMPORTED_VITALS_TAG_SYSTEM = APP_CONFIG.fetch('FHIR_IMPORTED_VITALS_TAG_SYSTEM', 'http://mahis.gov.mw/fhir/tags').freeze
      IMPORTED_VITALS_TAG_CODE = APP_CONFIG.fetch('FHIR_IMPORTED_VITALS_TAG_CODE', 'mahis-vitals-imported').freeze
      ICHIS_IDENTIFIER_SYSTEM = APP_CONFIG.fetch('ICHIS_IDENTIFIER_SYSTEM', 'https://ichis.org/ichisGeneratedID').freeze
      DHIS2_TEI_IDENTIFIER_SYSTEM = APP_CONFIG.fetch('DHIS2_TEI_IDENTIFIER_SYSTEM', 'https://dhis2.org/trackedEntityInstance').freeze
      SEARCH_RESULT_LIMIT = 1_000

      def patients
        page = normalized_positive_integer(params[:page], 1)
        per_page = normalized_positive_integer(params[:per_page] || params[:page_size] || params[:count], 10)
        per_page = [per_page, 100].min
        search = params[:search].to_s.strip

        bundle = search.present? ? search_patients_bundle(search, page, per_page) : fetch_patient_page_bundle(page, per_page)

        render json: patient_table_response(bundle, page, per_page)
      rescue RestClient::ExceptionWithResponse => e
        render json: { error: e.message, response: e.response }, status: :bad_request
      end

      def patient
        patient_id = params[:id]
        bundle = find_patient_bundle(patient_id)

        if bundle && bundle['entry'].present?
          render json: bundle
          return
        end

        render json: { errors: ["Patient/#{patient_id} not found"] }, status: :not_found
      rescue RestClient::ExceptionWithResponse => e
        render json: { errors: ["Patient/#{patient_id} not found"], response: e.response }, status: :not_found
      end


      def observations
        requested_id = params[:id]

        patient_bundle = find_patient_bundle(requested_id)
        resolved_patient_id = extract_patient_id_from_bundle(patient_bundle) || requested_id

        bundle = fetch_first_non_empty(
          [
            "#{BASE_FHIR_URL}/Observation?subject=Patient/#{CGI.escape(resolved_patient_id)}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
            "#{BASE_FHIR_URL}/Observation?subject=Patient/#{CGI.escape(resolved_patient_id)}"
          ],
          allow_empty_fallback: true
        )

        render json: filter_imported_referral_vitals(bundle)
      rescue RestClient::ExceptionWithResponse => e
        render json: { errors: ["Observations for Patient/#{requested_id} not found"], response: e.response }, status: :not_found
      end

      def mark_imported_observations
        observation_ids = normalize_array_param(params[:observation_ids])
        if observation_ids.blank?
          render json: { error: 'observation_ids is required' }, status: :bad_request
          return
        end

        response = ::FhirService.markReferralVitalsImportedInMediator(
          observation_ids: observation_ids,
          event_ids: normalize_array_param(params[:event_ids]),
          patient_identifier: params[:patient_identifier].to_s.strip.presence,
          tei: params[:tei].to_s.strip.presence
        )

        if mediator_success_response?(response)
          render json: {
            status: 'ok',
            imported_observations_count: observation_ids.length,
            response: parse_json_response(response&.body)
          }, status: :ok
          return
        end

        render json: {
          error: 'Unable to mark referral vitals as imported in FHIR',
          response: parse_json_response(response&.body)
        }, status: :bad_gateway
      rescue StandardError => e
        Rails.logger.error("Unable to mark referral vitals as imported in FHIR: #{e.class}: #{e.message}")
        render json: { error: 'Unable to mark referral vitals as imported in FHIR' }, status: :bad_gateway
      end

      def mahis_update_status
        tei = params[:tei].to_s.strip
        event_ids = params[:event_ids].to_s.split(',').map(&:strip).reject(&:blank?).uniq

        if tei.blank? && event_ids.blank?
          render json: { error: 'TEI or event_ids is required' }, status: :bad_request
          return
        end

        response = RestClient.get(
          mediator_endpoint('status'),
          {
            params: {
              tei: tei,
              event_ids: event_ids.join(',')
            },
            accept: :json
          }
        )

        render json: JSON.parse(response.body)
      rescue RestClient::ExceptionWithResponse => e
        render json: {
          error: 'Unable to fetch MAHIS update status from iCHIS',
          response: parse_json_response(e.response&.body)
        }, status: :bad_gateway
      rescue StandardError => e
        Rails.logger.error("Unable to fetch MAHIS update status from iCHIS: #{e.class}: #{e.message}")
        render json: { error: 'Unable to fetch MAHIS update status from iCHIS' }, status: :bad_gateway
      end

      private

      def mediator_endpoint(path)
        "#{BASE_MEDIATOR_URL.to_s.sub(%r{/*$}, '')}/#{path}"
      end

      def parse_json_response(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        body.to_s
      end

      def normalize_array_param(value)
        Array(value).flat_map { |item| item.is_a?(Array) ? item : item.to_s.split(',') }
                    .map(&:to_s)
                    .map(&:strip)
                    .reject(&:blank?)
                    .uniq
      end

      def mediator_success_response?(response)
        response&.code.to_i.between?(200, 299)
      end

      def fetch_json(url)
        response = RestClient.get(url, accept: 'application/fhir+json')
        JSON.parse(response.body)
      end

      def fhir_search_url(resource_type, query)
        compact_query = query.compact
        "#{BASE_FHIR_URL}/#{resource_type}?#{URI.encode_www_form(compact_query)}"
      end

      def fetch_first_non_empty(urls, allow_empty_fallback: false)
        last_response = nil

        urls.each do |url|
          current = fetch_json(url)
          last_response = current
          return current if current.is_a?(Hash) && current['entry'].present?
        end

        allow_empty_fallback ? (last_response || { 'resourceType' => 'Bundle', 'entry' => [] }) : nil
      end

      def patient_search_urls(patient_id)
        escaped_id = CGI.escape(patient_id.to_s)

        [
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(ICHIS_IDENTIFIER_SYSTEM)}|#{escaped_id}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(DHIS2_TEI_IDENTIFIER_SYSTEM)}|#{escaped_id}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
          "#{BASE_FHIR_URL}/Patient?_id=#{escaped_id}&_tag=#{CGI.escape(SYNC_STATUS_TAG)}",
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(ICHIS_IDENTIFIER_SYSTEM)}|#{escaped_id}",
          "#{BASE_FHIR_URL}/Patient?identifier=#{CGI.escape(DHIS2_TEI_IDENTIFIER_SYSTEM)}|#{escaped_id}",
          "#{BASE_FHIR_URL}/Patient?_id=#{escaped_id}"
        ]
      end

      def find_patient_bundle(patient_id)
        fetch_first_non_empty(patient_search_urls(patient_id))
      end

      def normalized_positive_integer(value, fallback)
        parsed = value.to_i
        parsed.positive? ? parsed : fallback
      end

      def fetch_patient_page_bundle(page, per_page)
        offset = (page - 1) * per_page
        common_query = {
          '_count' => per_page,
          '_offset' => offset,
          '_sort' => '-_lastUpdated',
          '_total' => 'accurate'
        }

        fetch_first_non_empty(
          [
            fhir_search_url('Patient', common_query.merge('_tag' => SYNC_STATUS_TAG)),
            fhir_search_url('Patient', common_query)
          ],
          allow_empty_fallback: true
        )
      end

      def search_patient_urls(search, limit = SEARCH_RESULT_LIMIT, tag: nil)
        common_query = {
          '_count' => limit,
          '_sort' => '-_lastUpdated',
          '_total' => 'accurate',
          '_tag' => tag
        }

        [
          fhir_search_url('Patient', common_query.merge('name' => search)),
          fhir_search_url('Patient', common_query.merge('identifier' => "#{ICHIS_IDENTIFIER_SYSTEM}|#{search}")),
          fhir_search_url('Patient', common_query.merge('identifier' => "#{DHIS2_TEI_IDENTIFIER_SYSTEM}|#{search}")),
          fhir_search_url('Patient', common_query.merge('_id' => search))
        ]
      end

      def patient_entries_from_urls(urls)
        urls.flat_map do |url|
          bundle = fetch_json(url)
          Array(bundle['entry']).select { |entry| entry.dig('resource', 'resourceType') == 'Patient' }
        rescue RestClient::ExceptionWithResponse => e
          Rails.logger.warn("FHIR patient search branch failed: #{e.message}")
          []
        end
      end

      def unique_patient_entries(entries)
        entries.each_with_object({}) do |entry, memo|
          resource = entry['resource'] || {}
          key = resource['id'].presence || entry['fullUrl'].presence
          next unless key

          memo[key] ||= entry
        end.values
      end

      def patient_last_updated(entry)
        entry.dig('resource', 'meta', 'lastUpdated').to_s
      end

      def search_patients_bundle(search, page, per_page)
        tagged_entries = unique_patient_entries(patient_entries_from_urls(search_patient_urls(search, tag: SYNC_STATUS_TAG)))
        entries = tagged_entries.presence || unique_patient_entries(patient_entries_from_urls(search_patient_urls(search)))

        sorted_entries = entries.sort_by { |entry| patient_last_updated(entry) }.reverse
        offset = (page - 1) * per_page

        {
          'resourceType' => 'Bundle',
          'type' => 'searchset',
          'total' => sorted_entries.length,
          'entry' => sorted_entries.slice(offset, per_page) || []
        }
      end

      def patient_table_response(bundle, page, per_page)
        entries = Array(bundle&.dig('entry')).select { |entry| entry.dig('resource', 'resourceType') == 'Patient' }
        total = (bundle&.dig('total') || entries.length).to_i

        {
          resourceType: 'ExternalReferralPatientPage',
          page: page,
          per_page: per_page,
          recordsTotal: total,
          recordsFiltered: total,
          data: entries.map { |entry| patient_table_row(entry) },
          bundle: bundle
        }
      end

      def patient_table_row(entry)
        patient = entry['resource'] || {}
        tei = patient_identifier_value(patient, DHIS2_TEI_IDENTIFIER_SYSTEM)
        ichis_generated_id = patient_identifier_value(patient, ICHIS_IDENTIFIER_SYSTEM)

        {
          id: patient['id'],
          fhirId: patient['id'],
          fullName: patient_name(patient),
          gender: patient['gender'],
          birthDate: patient['birthDate'],
          tei: tei,
          ichisGeneratedID: ichis_generated_id,
          updatedAt: patient.dig('meta', 'lastUpdated'),
          syncStatus: patient_sync_status(patient),
          primaryIdentifier: ichis_generated_id.presence || tei.presence || patient['id']
        }
      end

      def patient_name(patient)
        name = Array(patient['name']).first || {}
        given = Array(name['given']).join(' ')
        family = name['family'].to_s
        [given, family].map(&:presence).compact.join(' ').presence || 'Unknown'
      end

      def patient_identifier_value(patient, system)
        Array(patient['identifier']).find { |identifier| identifier['system'].to_s == system }&.dig('value')
      end

      def patient_sync_status(patient)
        tag = Array(patient.dig('meta', 'tag')).find { |item| item['code'].present? || item['display'].present? }
        tag&.dig('code') || tag&.dig('display') || 'Unknown'
      end

      def extract_patient_id_from_bundle(bundle)
        return nil unless bundle.is_a?(Hash)

        patient_entry = Array(bundle['entry']).find do |entry|
          entry.dig('resource', 'resourceType') == 'Patient'
        end

        patient_entry&.dig('resource', 'id')
      end

      def filter_imported_referral_vitals(bundle)
        return { 'resourceType' => 'Bundle', 'entry' => [] } unless bundle.is_a?(Hash)

        filtered_bundle = bundle.deep_dup
        entries = Array(filtered_bundle['entry'])
        filtered_entries = entries.reject { |entry| imported_referral_vital_observation?(entry) }
        filtered_bundle['entry'] = filtered_entries
        filtered_bundle['total'] = filtered_entries.length if filtered_bundle.key?('total')
        filtered_bundle
      end

      def imported_referral_vital_observation?(entry)
        resource = entry['resource'] || {}
        return false unless resource['resourceType'] == 'Observation'

        Array(resource.dig('meta', 'tag')).any? do |tag|
          tag_code = tag['code'].to_s.strip
          tag_display = tag['display'].to_s.strip
          tag_system = tag['system'].to_s.strip
          next false if tag_code.blank? && tag_display.blank?

          code_matches = [tag_code, tag_display].include?(IMPORTED_VITALS_TAG_CODE)
          system_matches = tag_system.blank? || tag_system == IMPORTED_VITALS_TAG_SYSTEM
          code_matches && system_matches
        end
      end
    end
  end
end
