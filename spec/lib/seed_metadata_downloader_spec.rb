# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'stringio'
require_relative '../../lib/seed_metadata_downloader'

RSpec.describe SeedMetadataDownloader do
  let(:primary) { 'https://example.test/github.sql' }
  let(:fallback) { 'https://example.test/fallback.sql' }
  let(:locations) { %w[location location_attribute location_attribute_type location_tag location_tag_map] }
  let(:destination) { File.join(@directory, 'metadata.sql') }
  let(:sql) do
    "-- MySQL dump 10.13\n" + (%w[concept concept_name drug] + locations).map do |table|
      "DROP TABLE IF EXISTS `#{table}`;\nCREATE TABLE `#{table}` (id INT);\nUNLOCK TABLES;\n"
    end.join + "-- Dump completed on 2026-09-09 14:30:05\n"
  end
  subject(:downloader) do
    described_class.new(primary_url: primary, fallback_url: fallback,
                        destination: destination, location_tables: locations)
  end

  around do |example|
    Dir.mktmpdir('metadata-spec') do |directory|
      @directory = directory
      example.run
    end
  end

  before do
    File.write(destination, 'previous metadata')
    allow(downloader).to receive(:sleep)
    allow(downloader).to receive(:puts)
    allow(downloader).to receive(:warn)
  end

  def http_error(status)
    OpenURI::HTTPError.new("#{status} failure", double(status: [status.to_s, 'failure']))
  end

  def serve(url, body)
    allow(URI).to receive(:open).with(url, any_args).and_yield(StringIO.new(body))
  end

  def expect_preserved_file
    expect(File.read(destination)).to eq('previous metadata')
    expect(Dir.children(@directory)).to eq(['metadata.sql'])
  end

  it 'uses GitHub when available without requesting the fallback' do
    serve(primary, sql)
    expect(URI).not_to receive(:open).with(fallback, any_args)
    expect(downloader.download!).to eq(primary)
    expect(File.read(destination)).to eq(sql)
    expect(Dir.children(@directory)).to eq(['metadata.sql'])
  end

  it 'retries persistent 503 failures five times then downloads the fallback' do
    allow(URI).to receive(:open).with(primary, any_args).and_raise(http_error(503))
    serve(fallback, sql)
    expect(downloader.download!).to eq(fallback)
    expect(URI).to have_received(:open).with(primary, any_args).exactly(5).times
    [10, 20, 30, 40].each { |delay| expect(downloader).to have_received(:sleep).with(delay).once }
    expect(File.read(destination)).to eq(sql)
  end

  it 'recovers from a temporary primary failure without using the fallback' do
    attempts = 0
    allow(URI).to receive(:open).with(primary, any_args) do |&block|
      attempts += 1
      raise http_error(503) if attempts == 1

      block.call(StringIO.new(sql))
    end
    expect(URI).not_to receive(:open).with(fallback, any_args)
    expect(downloader.download!).to eq(primary)
  end

  it 'moves straight to fallback for a missing primary file' do
    allow(URI).to receive(:open).with(primary, any_args).and_raise(http_error(404))
    serve(fallback, sql)
    expect(downloader.download!).to eq(fallback)
    expect(downloader).not_to have_received(:sleep)
  end

  [Timeout::Error, SocketError, Errno::ECONNRESET].each do |error|
    it "falls back after repeated #{error} failures" do
      allow(URI).to receive(:open).with(primary, any_args).and_raise(error)
      serve(fallback, sql)
      expect(downloader.download!).to eq(fallback)
      expect(URI).to have_received(:open).with(primary, any_args).exactly(5).times
    end
  end

  it 'reports both source failures and preserves the existing file' do
    allow(URI).to receive(:open).with(primary, any_args).and_raise(http_error(503))
    allow(URI).to receive(:open).with(fallback, any_args).and_raise(http_error(502))
    expect { downloader.download! }.to raise_error(described_class::DownloadError) do |error|
      expect(error.message).to include(primary, fallback, '503', '502')
    end
    expect_preserved_file
  end

  it 'rejects HTML, empty, truncated, and incomplete dumps before replacing the file' do
    invalid_bodies = ['', '<html>Service unavailable</html>',
                      sql.sub(/-- Dump completed.*\n/, ''),
                      sql.sub(/DROP TABLE IF EXISTS `location_tag`;.*?UNLOCK TABLES;\n/m, '')]
    invalid_bodies.each do |body|
      serve(primary, body)
      serve(fallback, body)
      expect { downloader.download! }.to raise_error(described_class::DownloadError)
      expect_preserved_file
    end
  end

  it 'uses a valid fallback after an invalid primary response' do
    serve(primary, '<html>Temporarily unavailable</html>')
    serve(fallback, sql)
    expect(downloader.download!).to eq(fallback)
    expect(File.read(destination)).to eq(sql)
  end

  it 'checks the advertised response length before accepting a download' do
    response = StringIO.new(sql)
    response.extend(OpenURI::Meta)
    allow(response).to receive(:meta).and_return('content-length' => (sql.bytesize + 1).to_s)
    allow(URI).to receive(:open).with(primary, any_args).and_yield(response)
    allow(URI).to receive(:open).with(fallback, any_args).and_raise(http_error(404))
    expect { downloader.download! }.to raise_error(described_class::DownloadError, /Content-Length/)
    expect_preserved_file
  end

  it 'does not switch sources for a local filesystem failure' do
    serve(primary, sql)
    expect(File).to receive(:rename).and_raise(Errno::EACCES)
    expect(URI).not_to receive(:open).with(fallback, any_args)
    expect { downloader.download! }.to raise_error(Errno::EACCES)
    expect_preserved_file
  end
end
