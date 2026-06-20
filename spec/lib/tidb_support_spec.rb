# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/tidb_support'

RSpec.describe TidbSupport do
  FakeConnection = Struct.new(:server_version) do
    def select_value(_query)
      server_version
    end
  end

  around do |example|
    previous_value = ENV.delete('TIDB_ENABLED')
    example.run
  ensure
    ENV['TIDB_ENABLED'] = previous_value unless previous_value.nil?
  end

  it 'detects and parses a supported TiDB version' do
    connection = FakeConnection.new('8.0.11-TiDB-v8.5.2')

    expect(described_class.enabled?(connection)).to be(true)
    expect(described_class.version(connection)).to eq(Gem::Version.new('8.5.2'))
    expect(described_class.supported?(connection)).to be(true)
  end

  it 'rejects a TiDB version older than the foreign-key baseline' do
    connection = FakeConnection.new('5.7.25-TiDB-v7.5.4')

    expect { described_class.verify_supported!(connection) }
      .to raise_error(RuntimeError, /requires TiDB 8\.5\.0 or newer/)
  end

  it 'does not identify MySQL as TiDB' do
    connection = FakeConnection.new('8.0.36 MySQL Community Server')

    expect(described_class.enabled?(connection)).to be(false)
    expect(described_class.version(connection)).to be_nil
  end
end
