# frozen_string_literal: true

require 'fileutils'
require 'open-uri'
require 'openssl'
require 'socket'
require 'tempfile'
require 'timeout'

class SeedMetadataDownloader
  class DownloadError < StandardError; end
  class InvalidMetadata < DownloadError; end

  MAX_ATTEMPTS = 5
  NETWORK_ERRORS = [Timeout::Error, SocketError, EOFError, IOError,
                    Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
                    Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EPIPE].freeze
  DOWNLOAD_ERRORS = [OpenURI::HTTPError, OpenSSL::SSL::SSLError, InvalidMetadata, *NETWORK_ERRORS].freeze

  def initialize(primary_url:, fallback_url:, destination:, location_tables:)
    @sources = [primary_url, fallback_url].uniq
    @destination = File.expand_path(destination.to_s)
    @location_tables = location_tables
  end

  # Returns the source URL so the importer can report which metadata it used.
  def download!
    FileUtils.mkdir_p(File.dirname(@destination))
    failures = []

    @sources.each_with_index do |url, index|
      puts "Trying fallback metadata source: #{url}" if index.positive?
      begin
        download_source!(url)
        puts "Metadata downloaded from #{url} to #{@destination}"
        return url
      rescue *DOWNLOAD_ERRORS => e
        failures << "#{url}: #{e.class}: #{e.message}"
        warn "Metadata source failed: #{failures.last}"
      end
    end

    raise DownloadError, "All metadata download sources failed:\n#{failures.join("\n")}"
  end

  private

  def download_source!(url)
    attempt = 0
    begin
      attempt += 1
      puts "Downloading metadata from #{url}... attempt #{attempt}/#{MAX_ATTEMPTS}"
      download_attempt!(url)
    rescue *DOWNLOAD_ERRORS => e
      raise unless retryable?(e) && attempt < MAX_ATTEMPTS

      delay = attempt * 10
      warn "Metadata download failed: #{e.message}. Retrying in #{delay} seconds..."
      sleep delay
      retry
    end
  end

  def retryable?(error)
    if error.is_a?(OpenURI::HTTPError)
      status = error.io.status.first.to_i
      [408, 429].include?(status) || (500..599).cover?(status)
    else
      NETWORK_ERRORS.any? { |type| error.is_a?(type) }
    end
  end

  def download_attempt!(url)
    Tempfile.create(['metadata_download_', '.sql'], File.dirname(@destination)) do |file|
      file.binmode
      URI.open(url, open_timeout: 30, read_timeout: 300,
                    'User-Agent' => 'MaHIS-Metadata-Seeder') do |remote|
        copied = IO.copy_stream(remote, file)
        if remote.respond_to?(:meta) && remote.meta['content-length'] &&
           [nil, 'identity'].include?(remote.meta['content-encoding']) &&
           copied != Integer(remote.meta['content-length'])
          raise InvalidMetadata, 'Metadata download length does not match Content-Length'
        end
      end
      file.flush
      validate_metadata!(file.path)
      file.close
      File.rename(file.path, @destination)
    end
  end

  def validate_metadata!(path)
    sql = File.binread(path)
    raise InvalidMetadata, 'Downloaded metadata is empty' if sql.empty?
    unless sql.start_with?('-- MySQL dump') && sql.match?(/^-- Dump completed on [^\r\n]+\s*\z/)
      raise InvalidMetadata, 'Downloaded metadata is not a complete MySQL dump'
    end

    missing_tables = %w[concept concept_name drug].reject do |table|
      sql.match?(/^CREATE TABLE `#{table}`\s*\(/)
    end
    missing_locations = @location_tables.reject do |table|
      sql.match?(/DROP TABLE IF EXISTS `#{Regexp.escape(table)}`;.*?UNLOCK TABLES;/m)
    end
    missing = missing_tables + missing_locations
    raise InvalidMetadata, "Metadata is missing required table blocks: #{missing.join(', ')}" if missing.any?
  end
end
