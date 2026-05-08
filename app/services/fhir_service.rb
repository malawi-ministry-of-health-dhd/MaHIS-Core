module FhirService
  class << self
    BASE_MEDIATOR_URL = YAML.safe_load(File.read('config/application.yml'))['BASE_MEDIATOR_URL']
    ICHIS_EVENT_SOURCE_CONCEPT_NAMES = [
      'Unspecified Diabetes',
      'Systolic',
      'Diastolic',
      'Waist circumference'
    ].freeze

    def sendEMRIdToMediator(data)
      begin
        response = RestClient.post(
          "#{BASE_MEDIATOR_URL}identifier",
          data.to_json,
          { content_type: :json, accept: :json }
        )
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
        response = RestClient.post(
          "#{BASE_MEDIATOR_URL}diagnosis",
          data.to_json,
          { content_type: :json, accept: :json }
        )
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

    private

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
  end
end
