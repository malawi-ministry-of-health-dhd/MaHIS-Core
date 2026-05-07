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
      latest_event_id = latest_diagnosis_event_id(patient_id)

      unless latest_event_id.present?
        Rails.logger.warn("Skipping confirmed diagnosis mediator send for patient #{patient_id}: missing iCHIS event id")
        return
      end

      data = { event_id: latest_event_id, diagnosis: diagnosis }

      begin
        response = RestClient.post(
          "#{BASE_MEDIATOR_URL}diagnosis",
          data.to_json,
          { content_type: :json, accept: :json }
        )
        puts "Success: #{response.code}"
        response
      rescue RestClient::ExceptionWithResponse => e
        puts "Failed to send diagnosis: #{e.response}"
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
