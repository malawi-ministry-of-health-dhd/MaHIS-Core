# frozen_string_literal: true

require 'utils/remappable_hash'

module Api
  module V1
    class EncountersController < ApplicationController
      # TODO: Move pretty much all CRUD ops in this module to EncounterService

      # Retrieve a list of encounters
      #
      # GET /encounter
      #
      # Optional parameters:
      #   patient_id: Retrieve encounters belonging to this patient
      #   location_id: Retrieve encounters at this location
      #   encounter_type_id: Retrieve encounters with this id only
      #   page, page_size: For pagination. Defaults to page 0 of size 12
      def index
        # Ignoring error value as required_params never errors when
        # retrieving optional parameters only
        filters = params.permit(%i[patient_id location_id encounter_type_id date program_id])

        if filters.empty?
          queryset = Encounter.all
        else
          remap_encounter_type_id! filters if filters[:encounter_type_id]
          date = filters.delete(:date)
          queryset = Encounter.where(filters)
          if date
            queryset = queryset.where('encounter_datetime BETWEEN DATE(?) AND (DATE(?) + INTERVAL 1 DAY)', date,
                                      date)
          end
        end

        queryset = queryset.includes(%i[type location program], 
                                      patient: { person: [:names] },
                                      provider: [:names],
                                      observations: { concept: %i[concept_names] })
                          .order(:date_created)

        render json: paginate(queryset)
      end

      # Generate a report on counts of various encounters
      #
      # POST /reports/encounters
      #
      # Optional parameters:
      #    all - Retrieves all encounters not just those created by current user
      def count
        encounter_types, = params.require(%i[encounter_types])

        complete_report = encounter_types.each_with_object({}) do |type_id, report|
          male_count = count_by_gender(type_id, 'M', params[:program_id].to_i, params[:date])
          fem_count = count_by_gender(type_id, 'F', params[:program_id].to_i, params[:date])
          report[type_id] = { 'M': male_count, 'F': fem_count }
        end

        render json: complete_report
      end

      # Retrieve single encounter.
      #
      # GET /encounter/:id
      def show
        render json: Encounter.find(params[:id])
      end

      # Create a new Encounter
      #
      # POST /encounter
      #
      # Required parameters:
      #   encounter_type_id: Encounter's type
      #   patient_id: Patient involved in the encounter
      #
      # Optional parameters:
      #   provider_id: user_id of surrogate doing the data entry defaults to current user
      def create
        type_id, patient_id, program_id = params.require(%i[encounter_type_id patient_id program_id])
        visit = params[:visit_id] ? Visit.find(params[:visit_id]) : (params[:visit] ? Visit.find(params[:visit]) : nil)
        encounter_datetime = TimeUtils.retro_timestamp(params[:encounter_datetime]&.to_time || Time.now)

        encounter = nil
        ActiveRecord::Base.transaction do
          encounter = encounter_service.create(
            type: EncounterType.find(type_id),
            patient: Patient.find(patient_id),
            program: Program.find(program_id),
            visit:,
            provider: params[:provider_id] ? User.find(params[:provider_id])&.person : User.current.person,
            encounter_datetime: encounter_datetime
          )

          save_observations(encounter, params[:obs]) if encounter.errors.empty? && params[:obs].present?
        end

        if encounter.errors.empty?
          enqueue_recent_patient_sync(encounter)
          render json: encounter.reload, status: :created
        else
          render json: encounter.errors, status: :bad_request
        end
      end

      # Update an existing encounter
      #
      # PUT /encounter/:id
      #
      # Optional parameters:
      #   encounter_type_id: Encounter's type
      #   patient_id: Patient involved in the encounter
      def update
        encounter = Encounter.find(params[:id])
        type = params[:type_id] && EncounterType.find(params[:type_id])
        patient = params[:patient_id] && Patient.find(params[:patient_id])
        provider = params[:provider_id] ? User.find(params[:provider_id])&.person : User.current.person
        encounter_datetime = TimeUtils.retro_timestamp(params[:encounter_datetime]&.to_time || Time.now)

        encounter_service.update(encounter, type:, patient:,
                                            provider:,
                                            encounter_datetime:)
      end

      # Void an existing encounter
      #
      # DELETE /encounter/:id
      def destroy
        encounter = Encounter.find(params[:id])
        reason = params[:reason] || "Voided by #{User.current.username}"
        encounter_service.void encounter, reason
      end

      private

      # HACK: Have to rename encounter_type_id because in the model
      # underneath it is unfortunately named encounter_type not
      # encounter_type_id. However, we prefer to use encounter_type_id
      # when receiving input from clients to retain an orthogonal
      # interface across the API. Can't be using person_id, patient_id,
      # etc and then surprise our clients with encounter_type as another
      # form of an id.
      def remap_encounter_type_id!(hash)
        hash.remap_field! :encounter_type_id, :encounter_type
      end

      def count_by_gender(type_id, gender, program_id, date = nil)
        filters = { encounter_type: type_id, program_id: }
        filters[:creator] = User.current.user_id unless params[:all]

        queryset = Encounter.where(filters)
        queryset = queryset.joins(
          'INNER JOIN person ON encounter.patient_id = person.person_id'
        ).where('person.gender = ?', gender)
        if params[:date]
          date = Date.strptime params[:date]
          queryset = queryset.where '(encounter_datetime BETWEEN (?) AND (?))',
                                    date.strftime('%Y-%m-%d 00:00:00'), date.strftime('%Y-%m-%d 23:59:59')
        end

        queryset.count
      end

      def encounter_service
        EncounterService.new
      end

      def observation_service
        ObservationService.new
      end

      def save_observations(encounter, obs_payload)
        obs_payload.each do |obs|
          observation_service.create_observation(encounter, normalize_observation(obs))
        end
      end

      def enqueue_recent_patient_sync(encounter)
        location_id = encounter.location_id.presence || Location.current&.location_id || User.current&.location_id
        # Without a resolvable location this would enqueue an ALL-locations sync
        # (which also triggers a full-database reconciliation) on a single
        # encounter save — skip rather than do that unintentionally.
        return if location_id.blank?

        Sync::BatchPatientSyncJob.perform_async(location_id, Sync::BatchPatientSyncJob.recent_since_date)
      end

      def normalize_observation(obs)
        raw = obs.respond_to?(:to_unsafe_h) ? obs.to_unsafe_h : obs.deep_dup
        concept_id = resolve_concept_id(raw['concept'] || raw[:concept] || raw['concept_id'] || raw[:concept_id])
        normalized = {
          concept_id:,
          obs_datetime: nil
        }

        normalized.merge!(extract_typed_value(raw))

        if normalized.slice(:value_boolean, :value_numeric, :value_drug,
                            :value_coded, :value_datetime, :value_text).values.all?(&:blank?)
          normalized.merge!(build_value_for_concept(concept_id, raw['value'] || raw[:value]))
        end

        group_members = raw['groupMembers'] || raw[:groupMembers] ||
                        raw['group_members'] || raw[:group_members] ||
                        raw['child'] || raw[:child] || raw['children'] || raw[:children]
        if group_members.present?
          normalized[:child] = group_members.map { |child| normalize_observation(child) }
        end

        normalized
      end

      def extract_typed_value(raw)
        {
          value_boolean: cast_boolean(raw['value_boolean'] || raw[:value_boolean] || raw['valueBoolean'] || raw[:valueBoolean]),
          value_numeric: raw['value_numeric'] || raw[:value_numeric] || raw['valueNumeric'] || raw[:valueNumeric],
          value_drug: raw['value_drug'] || raw[:value_drug] || raw['valueDrug'] || raw[:valueDrug],
          value_coded: resolve_coded_value(raw['value_coded'] || raw[:value_coded] || raw['valueCoded'] || raw[:valueCoded]),
          value_datetime: parse_client_datetime(raw['value_datetime'] || raw[:value_datetime] || raw['valueDatetime'] || raw[:valueDatetime]),
          value_text: raw['value_text'] || raw[:value_text] || raw['valueText'] || raw[:valueText]
        }.compact
      end

      def build_value_for_concept(concept_id, raw_value)
        return {} if raw_value.blank?

        concept = Concept.find(concept_id)
        datatype = concept.concept_datatype&.name&.downcase

        case datatype
        when 'boolean'
          { value_boolean: cast_boolean(raw_value) }
        when 'numeric'
          { value_numeric: raw_value }
        when 'date', 'datetime'
          { value_datetime: parse_client_datetime(raw_value) }
        when 'coded'
          { value_coded: resolve_coded_value(raw_value) }
        else
          { value_text: raw_value.to_s }
        end
      end

      def resolve_coded_value(value)
        return nil if value.blank?

        resolve_concept_id(value)
      rescue InvalidParameterError
        value
      end

      def resolve_concept_id(value)
        raise InvalidParameterError, 'Observation concept is required' if value.blank?

        return value.to_i if value.to_s.match?(/^\d+$/)

        concept = Concept.find_by(uuid: value.to_s)
        raise InvalidParameterError, "Invalid concept: #{value}" unless concept

        concept.concept_id
      end

      def parse_client_datetime(value)
        return nil if value.blank?

        if value.is_a?(Numeric) || value.to_s.match?(/^\d+$/)
          numeric = value.to_i
          # Frontend commonly sends milliseconds since epoch.
          return Time.at(numeric > 9_999_999_999 ? numeric / 1000.0 : numeric)
        end

        value.to_time
      rescue StandardError
        raise InvalidParameterError, "Invalid datetime: #{value}"
      end

      def cast_boolean(value)
        return nil if value.nil?
        return value if value == true || value == false

        %w[1 true yes y].include?(value.to_s.strip.downcase)
      end

    end
  end
end
