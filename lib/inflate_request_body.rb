# frozen_string_literal: true

require 'zlib'
require 'stringio'

# Inflates gzip-compressed request bodies before param parsing reads
# `rack.input`. The frontend gzips large JSON payloads (notably
# POST /save_patient_record) and sends `Content-Encoding: gzip`; neither
# nginx nor Rack decompresses request bodies, so we do it here. Requests
# without a gzip Content-Encoding pass straight through untouched.
class InflateRequestBody
  def initialize(app)
    @app = app
  end

  def call(env)
    encoding = env['HTTP_CONTENT_ENCODING']
    return @app.call(env) unless encoding&.include?('gzip')

    input = env['rack.input']
    return @app.call(env) unless input

    begin
      inflated = Zlib::GzipReader.new(input).read
    rescue Zlib::Error, Zlib::GzipFile::Error
      body = { error: 'Malformed gzip request body' }.to_json
      return [400, { 'Content-Type' => 'application/json' }, [body]]
    end

    env['rack.input'] = StringIO.new(inflated)
    env['CONTENT_LENGTH'] = inflated.bytesize.to_s
    # Drop the header so nothing downstream tries to decode the body again.
    env.delete('HTTP_CONTENT_ENCODING')

    @app.call(env)
  end
end