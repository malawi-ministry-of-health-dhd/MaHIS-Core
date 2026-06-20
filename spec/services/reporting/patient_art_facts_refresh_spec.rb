# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/reporting/patient_art_facts_refresh'

RSpec.describe Reporting::PatientArtFactsRefresh do
  class ArtFactsConnectionStub
    attr_reader :statements

    def initialize
      @statements = []
    end

    def transaction
      yield
    end

    def execute(sql)
      statements << sql
    end

    def select_value(_sql)
      12
    end
  end

  it 'refreshes all ART facts with set-based SQL and no stored functions' do
    connection = ArtFactsConnectionStub.new
    allow(TidbReporting).to receive(:with_analytics_session)
      .with(connection, materialize: true)
      .and_yield(connection)

    count = described_class.call(connection:)
    sql = connection.statements.join("\n")

    expect(count).to eq(12)
    expect(sql).to include('INSERT INTO reporting_patient_art_facts')
    expect(sql).to include('MIN(DATE(patient_state.start_date)) AS program_state_start_date')
    expect(sql).to include('GROUP BY patient_program.patient_id')
    expect(sql).not_to match(/date_antiretrovirals_started|patient_date_enrolled/i)
  end
end
