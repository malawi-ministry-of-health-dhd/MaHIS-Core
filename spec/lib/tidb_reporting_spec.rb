# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/tidb_reporting'

RSpec.describe TidbReporting do
  class ReportingConnectionStub
    attr_reader :statements

    def initialize
      @statements = []
    end

    def select_value(sql)
      return 'STRICT_TRANS_TABLES,NO_ZERO_DATE' if sql.include?('sql_mode')

      0
    end

    def execute(sql)
      statements << sql
    end

    def quote(value)
      "'#{value}'"
    end
  end

  it 'enables MPP and temporarily relaxes strict mode for materialization' do
    connection = ReportingConnectionStub.new
    allow(TidbSupport).to receive(:enabled?).with(connection).and_return(true)

    described_class.with_analytics_session(connection, materialize: true) { |_connection| nil }

    expect(connection.statements).to include("SET SESSION tidb_allow_mpp = '1'")
    expect(connection.statements).to include("SET SESSION tidb_enforce_mpp = '1'")
    expect(connection.statements).to include("SET SESSION tidb_enable_tiflash_read_for_write_stmt = '1'")
    expect(connection.statements).to include("SET SESSION sql_mode = 'NO_ZERO_DATE'")
    expect(connection.statements.last(4)).to include("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_DATE'")
  end

  it 'does not change session variables on MySQL' do
    connection = ReportingConnectionStub.new
    allow(TidbSupport).to receive(:enabled?).with(connection).and_return(false)

    described_class.with_analytics_session(connection) { |_connection| nil }

    expect(connection.statements).to be_empty
  end

  it 'allows TiKV fallback for report sessions by default' do
    connection = ReportingConnectionStub.new
    allow(TidbSupport).to receive(:enabled?).with(connection).and_return(true)

    described_class.with_analytics_session(connection) { |_connection| nil }

    expect(connection.statements).to include("SET SESSION tidb_allow_mpp = '1'")
    expect(connection.statements).to include("SET SESSION tidb_enforce_mpp = '0'")
  end
end
