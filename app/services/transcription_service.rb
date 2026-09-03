# frozen_string_literal: true

require 'net/http'

# Turns a dictated recording into text.
#
# Rails does not run the speech model itself - there is no serious Ruby binding
# for Whisper. A separate process on this host does the work and is reached over
# loopback only; it is never exposed to the network, because this service is what
# authenticates the caller.
#
# The audio is patient data. It is held in memory for the length of one request
# and is never written to disk, the database, or the logs.
class TranscriptionService
  class TranscriptionError < StandardError; end

  # Desktop and Android carry their own model, so only browser dictation arrives
  # here. Thirty seconds of Opus is around 120KB; the ceiling exists to reject
  # anything that is clearly not a clinical note.
  MAX_AUDIO_BYTES = 10.megabytes

  DEFAULT_ENDPOINT = 'http://127.0.0.1:8383/inference'

  def self.endpoint
    ENV.fetch('MAHIS_TRANSCRIPTION_URL', DEFAULT_ENDPOINT)
  end

  def self.timeout_seconds
    Integer(ENV.fetch('MAHIS_TRANSCRIPTION_TIMEOUT', '120'))
  end

  # Returns the transcript, or raises TranscriptionError with a message safe to
  # show a clinician.
  def self.transcribe(audio_file)
    raise TranscriptionError, 'No audio was received' if audio_file.blank?

    size = audio_file.size.to_i
    raise TranscriptionError, 'No audio was received' if size.zero?
    raise TranscriptionError, 'Recording is too long' if size > MAX_AUDIO_BYTES

    response = post_to_engine(audio_file)
    extract_text(response)
  end

  def self.post_to_engine(audio_file)
    uri = URI.parse(endpoint)

    form = [['file', audio_file.tempfile, { filename: audio_file.original_filename || 'dictation.webm' }]]
    request = Net::HTTP::Post.new(uri)
    request.set_form(form, 'multipart/form-data')

    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5
    http.read_timeout = timeout_seconds

    http.request(request)
  rescue Errno::ECONNREFUSED, Net::OpenTimeout
    # The engine is a separate service; if it is down, dictation is unavailable
    # but the rest of MaHIS is unaffected.
    raise TranscriptionError, 'The transcription service is not running'
  rescue Net::ReadTimeout
    raise TranscriptionError, 'Transcription took too long'
  end
  private_class_method :post_to_engine

  def self.extract_text(response)
    raise TranscriptionError, 'Transcription failed' unless response.is_a?(Net::HTTPSuccess)

    # whisper.cpp's server returns {"text": "..."}; tolerate a bare string too.
    parsed = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      { 'text' => response.body }
    end

    text = parsed.is_a?(Hash) ? parsed['text'] : parsed
    text.to_s.strip
  end
  private_class_method :extract_text
end
