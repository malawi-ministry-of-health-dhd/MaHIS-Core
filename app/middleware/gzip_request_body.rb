# frozen_string_literal: true

require 'zlib'
require 'stringio'

# Decompresses gzip-encoded request bodies before Rails reads them, so
# ActionDispatch::Http::Parameters sees plain JSON instead of raw gzip bytes.
# Counterpart to MAHIS frontend's `Service.postJson(url, data, { compress: true })`,
# which gzips large payloads (e.g. save_patient_record) and sends `Content-Encoding: gzip`.
class GzipRequestBody
  def initialize(app)
    @app = app
  end

  def call(env)
    content_encoding = env['HTTP_CONTENT_ENCODING'].to_s.downcase
    Rails.logger.debug "[GzipRequestBody] Content-Encoding: #{content_encoding}"

    if content_encoding == 'gzip'
      begin
        Rails.logger.debug "[GzipRequestBody] Decompressing gzip body, original size: #{env['CONTENT_LENGTH']}"
        body = Zlib::GzipReader.new(env['rack.input']).read
        Rails.logger.debug "[GzipRequestBody] Decompressed to size: #{body.bytesize}"
        
        env['rack.input'] = StringIO.new(body)
        env['CONTENT_LENGTH'] = body.bytesize.to_s
        env.delete('HTTP_CONTENT_ENCODING')
      rescue Zlib::GzipFile::Error, Zlib::DataError => e
        Rails.logger.error "[GzipRequestBody] Decompression failed: #{e.message}"
        return [400, { 'Content-Type' => 'application/json' }, [{ errors: ['Malformed gzip request body'] }.to_json]]
      end
    end

    @app.call(env)
  end
end
