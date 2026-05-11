module FhirService
  class << self
    APP_CONFIG = YAML.safe_load(File.read('config/application.yml'))
    BASE_MEDIATOR_URL = APP_CONFIG['BASE_MEDIATOR_URL']
    IMPORTED_VITALS_TAG_SYSTEM = APP_CONFIG.fetch('FHIR_IMPORTED_VITALS_TAG_SYSTEM', 'http://mahis.gov.mw/fhir/tags').freeze
    IMPORTED_VITALS_TAG_CODE = APP_CONFIG.fetch('FHIR_IMPORTED_VITALS_TAG_CODE', 'mahis-vitals-imported').freeze
    IMPORTED_VITALS_MEDIATOR_ENDPOINTS = [
      'status/referral_vitals_import',
      'referral_vitals/import_status',
      'status/imported_vitals'
    ].freeze
    ICHIS_EVENT_SOURCE_CONCEPT_NAMES = [
      'Unspecified Diabetes',
      'Systolic',
      'Diastolic',
      'Waist circumference'
    ].freeze
    NCD_PROGRAM_ID = 32
    PRIMARY_DIAGNOSIS_CONCEPT_NAME = 'primary diagnosis'.freeze
    NOTES_ENCOUNTER_TYPE_NAME = 'notes'.freeze
    TREATMENT_ENCOUNTER_TYPE_NAME = 'treatment'.freeze
    NCD_IDENTIFIER_TYPE_NAME = 'ncd number'.freeze
    DIABETES_DIAGNOSIS_ALIASES = [
      'unspecified diabetes',
      'type 1 diabetes mellitus',
      'type 2 diabetes mellitus',
      'diabetes'
    ].freeze
    HYPERTENSION_DIAGNOSIS_ALIASES = ['hypertension', 'hypertation'].freeze

    def sendEMRIdToMediator(data)
      begin
        response = post_to_mediator('identifier', data)
        puts "Success: #{response.code}"
        response
      rescue RestClient::ExceptionWithResponse => e
        puts "Failed to send EMR ID: #{e.response}"
        e.response
      rescue StandardError => e
        puts "Other error: #{e.message}"
        nil
      end
    end

    def sendConfirmedDiagnosisToMediator(patient_id, diagnosis)
      sendReferralResultsToMediator(patient_id, diagnosis: diagnosis)
    end

    def sendReferralResultsToMediator(patient_id, diagnosis: nil, treatment_plan: nil, enrolled_in_care: nil, event_id: nil)
      latest_event_id = event_id.presence || latest_diagnosis_event_id(patient_id)
      unless latest_event_id.present?
        Rails.logger.warn("Skipping referral results mediator send for patient #{patient_id}: missing iCHIS event id")
        return
      end

      diagnoses = Array(diagnosis).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      treatment_plan_text = normalize_treatment_plan(treatment_plan)

      data = { event_id: latest_event_id }
      data[:diagnosis] = diagnoses if diagnoses.present?
      data[:treatment_plan] = treatment_plan_text if treatment_plan_text.present?
      data[:enrolled_in_care] = boolean_value(enrolled_in_care) unless enrolled_in_care.nil?

      return if data.keys == [:event_id]

      begin
        response = post_to_mediator('diagnosis', data)
        puts "Success: #{response.code}"
        response
      rescue RestClient::ExceptionWithResponse => e
        puts "Failed to send referral results: #{e.response}"
        e.response
      rescue StandardError => e
        puts "Other error: #{e.message}"
        nil
      end
    end

    def markReferralVitalsImportedInMediator(observation_ids:, event_ids: [], patient_identifier: nil, tei: nil)
      normalized_observation_ids = normalize_string_array(observation_ids)
      return nil if normalized_observation_ids.blank?

      payload = {
        observation_ids: normalized_observation_ids,
        event_ids: normalize_string_array(event_ids),
        imported_tag: {
          system: IMPORTED_VITALS_TAG_SYSTEM,
          code: IMPORTED_VITALS_TAG_CODE
        }
      }
      payload[:patient_identifier] = patient_identifier.to_s.strip if patient_identifier.present?
      payload[:tei] = tei.to_s.strip if tei.present?

      last_response = nil
      IMPORTED_VITALS_MEDIATOR_ENDPOINTS.each do |endpoint|
        begin
          response = post_to_mediator(endpoint, payload)
          return response if response&.code.to_i.between?(200, 299)

          last_response = response
        rescue RestClient::ExceptionWithResponse => e
          Rails.logger.warn("Failed to post imported referral vitals to mediator endpoint '#{endpoint}': #{e.response}")
          last_response = e.response
          next
        rescue StandardError => e
          Rails.logger.warn("Error posting imported referral vitals to mediator endpoint '#{endpoint}': #{e.class}: #{e.message}")
          next
        end
      end

      last_response
    end

    def syncReferralStatusForPatient(patient_id:, tei: nil, event_id: nil)
      normalized_patient_id = patient_id.to_i
      return { success: false, reason: 'missing_patient_id' } unless normalized_patient_id.positive?

      patient = Patient.find_by(patient_id: normalized_patient_id)
      return { success: false, reason: 'patient_not_found', patient_id: normalized_patient_id } if patient.blank?

      normalized_tei = tei.to_s.strip
      resolved_event_id = event_id.to_s.strip.presence || latest_diagnosis_event_id(normalized_patient_id).to_s.strip.presence
      diagnoses = latest_confirmed_ncd_diagnoses(normalized_patient_id)
      treatment_plan = latest_ncd_treatment_plan_values(normalized_patient_id)
      enrolled_in_care = enrolled_in_ncd_care?(normalized_patient_id)
      mahis_identifier = preferred_mahis_identifier(patient)

      identifier_sync = {
        attempted: false,
        status: normalized_tei.present? ? 'missing_identifier' : 'skipped',
        code: nil
      }
      if normalized_tei.present? && mahis_identifier.present?
        identifier_sync[:attempted] = true
        identifier_response = sendEMRIdToMediator(
          identifier: mahis_identifier,
          TEI: normalized_tei
        )
        identifier_sync[:code] = identifier_response&.code.to_i if identifier_response&.code
        identifier_sync[:status] = successful_mediator_response?(identifier_response) ? 'updated' : 'error'
      end

      referral_sync = {
        attempted: false,
        status: resolved_event_id.present? ? 'pending' : 'missing_event_id',
        code: nil
      }
      if resolved_event_id.present?
        referral_sync[:attempted] = true
        referral_response = sendReferralResultsToMediator(
          normalized_patient_id,
          diagnosis: diagnoses,
          treatment_plan: treatment_plan,
          enrolled_in_care: enrolled_in_care,
          event_id: resolved_event_id
        )
        referral_sync[:code] = referral_response&.code.to_i if referral_response&.code
        referral_sync[:status] = successful_mediator_response?(referral_response) ? 'updated' : 'error'
      end

      {
        success: [identifier_sync, referral_sync].any? { |item| item[:status] == 'updated' },
        patient_id: normalized_patient_id,
        tei: normalized_tei,
        event_id: resolved_event_id.to_s,
        mahis_identifier: mahis_identifier.to_s,
        diagnosis: diagnoses,
        treatment_plan: treatment_plan,
        enrolled_in_care: enrolled_in_care,
        identifier_sync: identifier_sync,
        referral_sync: referral_sync
      }
    end

    def retryReferralStatusSyncBatch(limit: 100, lookback_hours: 72)
      normalized_limit = limit.to_i
      normalized_limit = 1 if normalized_limit <= 0
      normalized_limit = [normalized_limit, 500].min

      normalized_lookback_hours = lookback_hours.to_i
      normalized_lookback_hours = 72 if normalized_lookback_hours <= 0
      cutoff_time = normalized_lookback_hours.hours.ago

      candidate_patient_ids = referral_status_candidate_patient_ids(
        limit: normalized_limit,
        cutoff_time: cutoff_time
      )

      summary = {
        success: true,
        limit: normalized_limit,
        lookback_hours: normalized_lookback_hours,
        cutoff_time: cutoff_time.iso8601,
        candidates: candidate_patient_ids.length,
        attempted: 0,
        updated: 0,
        failed: 0,
        skipped: 0,
        patients: []
      }

      candidate_patient_ids.each do |patient_id|
        begin
          patient = Patient.find_by(patient_id: patient_id)
          if patient.blank?
            summary[:skipped] += 1
            summary[:patients] << {
              patient_id: patient_id,
              status: 'skipped',
              reason: 'patient_not_found'
            }
            next
          end

          event_id = latest_diagnosis_event_id(patient_id).to_s.strip
          tei = BuildPatientRecordService.extract_tei(patient).to_s.strip

          if tei.blank? && event_id.blank?
            summary[:skipped] += 1
            summary[:patients] << {
              patient_id: patient_id,
              status: 'skipped',
              reason: 'missing_tei_and_event_id'
            }
            next
          end

          summary[:attempted] += 1
          sync_result = syncReferralStatusForPatient(
            patient_id: patient_id,
            tei: tei,
            event_id: event_id
          )

          status = sync_result[:success] ? 'updated' : 'error'
          summary[:updated] += 1 if status == 'updated'
          summary[:failed] += 1 if status == 'error'

          summary[:patients] << {
            patient_id: patient_id,
            status: status,
            tei: tei,
            event_id: event_id,
            identifier_sync: sync_result[:identifier_sync],
            referral_sync: sync_result[:referral_sync]
          }
        rescue StandardError => e
          summary[:failed] += 1
          summary[:patients] << {
            patient_id: patient_id,
            status: 'error',
            error: e.message
          }
          Rails.logger.error("Retry referral status sync failed for patient #{patient_id}: #{e.class}: #{e.message}")
        end
      end

      summary[:success] = summary[:failed].zero?
      summary
    end

    private

    def post_to_mediator(path, data)
      RestClient.post(
        mediator_endpoint(path),
        data.to_json,
        { content_type: :json, accept: :json }
      )
    end

    def mediator_endpoint(path)
      "#{BASE_MEDIATOR_URL.to_s.sub(%r{/*$}, '')}/#{path.to_s.sub(%r{^/*}, '')}"
    end

    def normalize_string_array(values)
      Array(values).map { |value| value.to_s.strip }.reject(&:blank?).uniq
    end

    def latest_diagnosis_event_id(patient_id)
      Observation.where(concept_id: ichis_event_source_concept_ids, person_id: patient_id)
                 .where.not(comments: [nil, ''])
                 .order(obs_datetime: :desc, obs_id: :desc)
                 .limit(1)
                 .pluck(:comments)
                 .first
    end

    def normalize_treatment_plan(treatment_plan)
      Array(treatment_plan).map(&:to_s).map(&:strip).reject(&:blank?).uniq.join('; ')
    end

    def boolean_value(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def ichis_event_source_concept_ids
      @ichis_event_source_concept_ids ||= begin
        concept_ids = ConceptName.where(name: ICHIS_EVENT_SOURCE_CONCEPT_NAMES, voided: 0)
                                 .distinct
                                 .pluck(:concept_id)
        concept_ids.compact.uniq
      end
    end

    def successful_mediator_response?(response)
      response&.code.to_i.between?(200, 299)
    end

    def referral_status_candidate_patient_ids(limit:, cutoff_time:)
      concept_ids = ichis_event_source_concept_ids
      return [] if concept_ids.blank?

      Observation.where(voided: 0, concept_id: concept_ids)
                 .where('obs_datetime >= ?', cutoff_time)
                 .where.not(comments: [nil, ''])
                 .order(obs_datetime: :desc, obs_id: :desc)
                 .limit(limit * 4)
                 .pluck(:person_id)
                 .map(&:to_i)
                 .select(&:positive?)
                 .uniq
                 .first(limit)
    end

    def preferred_mahis_identifier(patient)
      return '' if patient.blank?

      identifier =
        PatientIdentifier.where(patient_id: patient.patient_id, voided: 0)
                         .joins(:type)
                         .order(preferred: :desc, date_created: :desc, patient_identifier_id: :desc)
                         .detect do |item|
                           type_name = normalize_concept_name(item.type&.name)
                           type_name.present? && type_name != NCD_IDENTIFIER_TYPE_NAME && !type_name.include?('ichis')
                         end
      identifier&.identifier.to_s.strip
    end

    def latest_confirmed_ncd_diagnoses(patient_id)
      concept_id = concept_id_by_name(PRIMARY_DIAGNOSIS_CONCEPT_NAME)
      return [] unless concept_id

      coded_diagnosis_ids = Observation.where(person_id: patient_id, concept_id: concept_id, voided: 0)
                                       .where.not(value_coded: [nil, 0])
                                       .order(obs_datetime: :desc, obs_id: :desc)
                                       .limit(15)
                                       .pluck(:value_coded)
                                       .map(&:to_i)
                                       .select(&:positive?)
                                       .uniq
      return [] if coded_diagnosis_ids.blank?

      diagnosis_names = ConceptName.where(concept_id: coded_diagnosis_ids, voided: 0).pluck(:name).map { |name| normalize_concept_name(name) }
      diagnoses = []
      diagnoses << 'Diabetes' if diagnosis_names.any? { |name| DIABETES_DIAGNOSIS_ALIASES.any? { |alias_name| name.include?(alias_name) } }
      diagnoses << 'Hypertension' if diagnosis_names.any? { |name| HYPERTENSION_DIAGNOSIS_ALIASES.any? { |alias_name| name.include?(alias_name) } }
      diagnoses
    end

    def latest_ncd_treatment_plan_values(patient_id)
      plans = []

      notes_encounter_type_id = encounter_type_id_by_name(NOTES_ENCOUNTER_TYPE_NAME)
      if notes_encounter_type_id
        notes_values = Observation.joins(:encounter)
                                  .where(person_id: patient_id, voided: 0)
                                  .where(encounter: { voided: 0, program_id: NCD_PROGRAM_ID, encounter_type: notes_encounter_type_id })
                                  .where.not(value_text: [nil, ''])
                                  .order(obs_datetime: :desc, obs_id: :desc)
                                  .limit(10)
                                  .pluck(:value_text)
        plans.concat(notes_values)
      end

      treatment_encounter_type_id = encounter_type_id_by_name(TREATMENT_ENCOUNTER_TYPE_NAME)
      if treatment_encounter_type_id
        treatment_orders = Order.joins(:drug_order, :encounter)
                                .where(patient_id: patient_id, voided: 0)
                                .where(encounter: {
                                         voided: 0,
                                         program_id: NCD_PROGRAM_ID,
                                         encounter_type: treatment_encounter_type_id
                                       })
                                .order(start_date: :desc, order_id: :desc)
                                .limit(10)
        treatment_plans = treatment_orders.map { |order| order.drug_order&.to_s }.compact
        plans.concat(treatment_plans)
      end

      plans.map { |plan| plan.to_s.strip }.reject(&:blank?).uniq
    end

    def enrolled_in_ncd_care?(patient_id)
      has_ncd_program = PatientProgram.where(patient_id: patient_id, program_id: NCD_PROGRAM_ID, voided: 0).exists?
      return true if has_ncd_program

      ncd_identifier_type_id = ncd_identifier_type_id_by_name
      return false unless ncd_identifier_type_id

      PatientIdentifier.where(
        patient_id: patient_id,
        identifier_type: ncd_identifier_type_id,
        voided: 0
      ).exists?
    end

    def ncd_identifier_type_id_by_name
      @ncd_identifier_type_id_by_name ||= begin
        PatientIdentifierType.where(retired: 0)
                             .where('LOWER(name) = ?', NCD_IDENTIFIER_TYPE_NAME)
                             .order(:patient_identifier_type_id)
                             .limit(1)
                             .pick(:patient_identifier_type_id)
      end
    end

    def concept_id_by_name(name)
      normalized_name = normalize_concept_name(name)
      return nil if normalized_name.blank?

      ConceptName.where(voided: 0)
                 .where('LOWER(name) = ?', normalized_name)
                 .order(:concept_name_id)
                 .limit(1)
                 .pick(:concept_id)
    end

    def encounter_type_id_by_name(name)
      normalized_name = normalize_concept_name(name)
      return nil if normalized_name.blank?

      EncounterType.where(retired: 0)
                   .where('LOWER(name) = ?', normalized_name)
                   .order(:encounter_type_id)
                   .limit(1)
                   .pick(:encounter_type_id)
    end

    def normalize_concept_name(name)
      name.to_s.downcase.squish
    end
  end
end
