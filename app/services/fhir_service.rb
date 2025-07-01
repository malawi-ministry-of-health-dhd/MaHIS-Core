module FhirService
  class << self
    BASE_MEDIATOR_URL = 'http://localhost:3001/emr/' 
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

    def sendConfirmedDiagnosisToMediator(data)
      latest_event_id = Observation.where(concept_id: 11587, person_id: data[:patient_id])
                            .order(obs_datetime: :desc)
                            .limit(1)
                            .pluck(:comments)
                            .first
        data ={
          event_id: latest_event_id,

                            }
      # response = RestClient.post()
    rescue RestClient::ExceptionWithResponse => e
    end
  end
end
