# frozen_string_literal: true

require 'rails_helper'
require './spec/support/helpers/aetc_migration_fixture'

# End-to-end test of the AETC -> MaHIS migration (rake aetc:migrate) on throwaway schemas.
# The fixture (spec/support/helpers/aetc_migration_fixture.rb) seeds a few AETC patients, each covering a rule.
RSpec.describe 'AETC migration' do # rubocop:disable RSpec/DescribeClass
  fixture = AetcMigrationFixture

  after(:all) { fixture.drop }

  def row(sql)
    rows = AetcMigrationFixture.query(sql)
    expect(rows.size).to eq(1), "expected one row for #{sql}, got #{rows.size}"
    rows.first
  end

  def logged?(entity, src_id, reason)
    AetcMigrationFixture.logged(reason).include?([entity, src_id])
  end

  context 'with DRY_RUN' do
    before(:all) do
      fixture.build
      @before = fixture.counts
      fixture.migrate(dry_run: true)
    end

    it 'changes nothing in MaHIS or in id_map' do
      expect(fixture.counts).to eq(@before)
      expect(fixture.query('SELECT * FROM trk.id_map')).to be_empty
    end
  end

  context 'with a full run' do
    before(:all) do
      fixture.build
      fixture.migrate
    end

    it 'loads the expected rows' do
      expect(fixture.counts).to eq(fixture::FULL_RUN_COUNTS)
    end

    it 'creates one migration user, without a password, for all AETC users' do
      user = row("SELECT user_id, password FROM tgt.users WHERE username = 'aetc_migration'")
      expect(user['password']).to be_nil
      lookup = row('SELECT COUNT(*) n, MIN(target_user_id) lo, MAX(target_user_id) hi FROM trk.users_lookup')
      expect(lookup.values_at('n', 'lo', 'hi')).to eq([408, user['user_id'], user['user_id']])
    end

    it 'skips user-only persons and persons whose uuid MaHIS already has' do
      expect(fixture.query("SELECT 1 FROM tgt.person WHERE uuid = 's-person-900'")).to be_empty
      expect(logged?('person', 900, 'user_only_person')).to be(true)
      expect(logged?('person', 106, 'uuid_exists_in_target')).to be(true)
    end

    it 'skips Dummy identifiers and flags identifiers shared by two patients' do
      expect(fixture.query("SELECT 1 FROM tgt.patient_identifier WHERE identifier = '103VWY7'")).to be_empty
      expect(logged?('patient_identifier', 2, 'identifier_type_skipped')).to be(true)
      expect(fixture.query("SELECT 1 FROM tgt.patient_identifier WHERE identifier = 'DUP1'").size).to eq(2)
      expect(logged?('patient_identifier', 5, 'duplicate_identifier')).to be(true)
    end

    it 'brings the voided rows of a voided patient, as voided' do
      expect(row("SELECT voided FROM tgt.visit WHERE uuid = 's-visit-3'")['voided']).to eq(1)
      expect(row("SELECT voided FROM tgt.encounter WHERE uuid = 's-enc-5'")['voided']).to eq(1)
      expect(row("SELECT voided FROM tgt.obs WHERE uuid = 's-obs-11'")['voided']).to eq(1)
      expect(row("SELECT voided FROM tgt.orders WHERE uuid = 's-order-6'")['voided']).to eq(1)
    end

    it 'leaves out voided rows of active patients' do
      %w[visit.s-visit-2 encounter.s-enc-4 obs.s-obs-10 orders.s-order-5].each do |name|
        table, uuid = name.split('.', 2)
        expect(fixture.query("SELECT 1 FROM tgt.#{table} WHERE uuid = '#{uuid}'")).to be_empty, name
      end
    end

    it 'skips dangling relationships and relationships to persons that were not migrated' do
      expect(logged?('relationship', 3, 'dangling_relationship')).to be(true)
      expect(logged?('relationship', 5, 'person_not_migrated')).to be(true)
      expect(logged?('relationship', 4, 'relationship_type_unmapped')).to be(true)
    end

    it 'puts encounters at AETC location 1 (Unknown) at QECH (1291), logged' do
      expect(row("SELECT location_id FROM tgt.encounter WHERE uuid = 's-enc-6'")['location_id'].to_s).to eq('1291')
      expect(logged?('encounter', 6, 'location_overridden')).to be(true)
      expect(row("SELECT location_id FROM tgt.encounter WHERE uuid = 's-enc-2'")['location_id'].to_s).to eq('676')
    end

    it 'keeps encounters whose visit was not migrated, without a visit' do
      expect(row("SELECT visit_id FROM tgt.encounter WHERE uuid = 's-enc-7'")['visit_id']).to be_nil
      expect(logged?('encounter', 7, 'visit_not_migrated')).to be(true)
      expect(logged?('encounter', 3, 'encounter_type_unmapped')).to be(true)
    end

    it 'migrates lab orders, dropping fractions of seconds and filling an empty start date' do
      order = row("SELECT start_date, discontinued_date FROM tgt.orders WHERE uuid = 's-order-1'")
      expect(order['discontinued_date'].strftime('%F %T')).to eq('2024-02-01 10:00:00')
      expect(logged?('order', 2, 'start_date_filled')).to be(true)
      expect(logged?('order', 7, 'accession_exists_in_target')).to be(true)
      expect(logged?('order', 3, 'encounter_not_migrated')).to be(true)
      expect(logged?('order', 4, 'specimen_unmapped')).to be(true)
      expect(logged?('order', 8, 'order_type_unmapped')).to be(true)
      expect(logged?('lims_order_mapping', 2, 'lims_id_exists_in_target')).to be(true)
    end

    it 'converts reviewed text answers to coded ones, ignoring surrounding whitespace' do
      %w[s-obs-5 s-obs-15].each do |uuid|
        obs = row("SELECT value_coded, value_text FROM tgt.obs WHERE uuid = '#{uuid}'")
        expect(obs.values_at('value_coded', 'value_text')).to eq([37_452, nil]), uuid
      end
    end

    it 'keeps as text what it cannot convert, and logs why' do
      expect(row("SELECT value_text FROM tgt.obs WHERE uuid = 's-obs-12'")['value_text']).to eq('Positive')
      expect(logged?('obs', 12, 'value_unmapped')).to be(true)
      expect(logged?('obs', 9, 'answer_unmapped')).to be(true)
    end

    it 'stores every result of the AETC lab tests as text, numbers included (decision 2026-10-12)' do
      number = row("SELECT value_numeric, value_text FROM tgt.obs WHERE uuid = 's-obs-17'")
      expect(number.values_at('value_numeric', 'value_text')).to eq([nil, '4.3'])
      text = row("SELECT value_numeric, value_text FROM tgt.obs WHERE uuid = 's-obs-6'")
      expect(text.values_at('value_numeric', 'value_text')).to eq([nil, 'nil'])
      expect(logged?('obs', 6, 'conversion_not_reviewed')).to be(false)
    end

    it 'maps the AETC blood-gas concepts by id (decision 2026-10-13)' do
      obs = row("SELECT concept_id, value_text FROM tgt.obs WHERE uuid = 's-obs-18'")
      expect(obs.values_at('concept_id', 'value_text')).to eq([48_838, '40.2'])
    end

    it 'handles a text with a long run of spaces (MySQL regexp_time_limit)' do
      expect(row("SELECT CHAR_LENGTH(value_text) len FROM tgt.obs WHERE uuid = 's-obs-16'")['len']).to eq(5008)
      expect(logged?('obs', 16, 'value_unmapped')).to be(true)
    end

    it 'skips obs whose concept or encounter was not migrated' do
      expect(logged?('obs', 7, 'concept_unmapped')).to be(true)
      expect(logged?('obs', 8, 'encounter_not_migrated')).to be(true)
    end

    it 'keeps obs groups and order links' do
      child = row("SELECT g.uuid FROM tgt.obs o JOIN tgt.obs g ON g.obs_id = o.obs_group_id WHERE o.uuid = 's-obs-4'")
      expect(child['uuid']).to eq('s-obs-3')
      linked = row("SELECT od.uuid FROM tgt.obs o JOIN tgt.orders od ON od.order_id = o.order_id WHERE o.uuid = 's-obs-13'")
      expect(linked['uuid']).to eq('s-order-1')
      expect(logged?('obs', 14, 'order_not_migrated')).to be(true)
    end

    it 'adds nothing when run again' do
      logs = fixture.query('SELECT COUNT(*) n FROM trk.migration_log').first['n']
      fixture.migrate
      expect(fixture.counts).to eq(fixture::FULL_RUN_COUNTS)
      expect(fixture.query('SELECT COUNT(*) n FROM trk.migration_log').first['n']).to eq(logs)
    end
  end

  context 'with LIMIT, then the rest' do
    before(:all) do
      fixture.build
      fixture.migrate(limit: 2)
      @partial = fixture.query("SELECT src_id FROM trk.id_map WHERE entity = 'person' ORDER BY src_id").map { |r| r['src_id'] }
      @partial_visits = fixture.counts['visit']
      fixture.migrate
    end

    it 'migrates only the next n AETC persons first' do
      expect(@partial).to eq([101, 102])
      expect(@partial_visits).to eq(1)
    end

    it 'ends with the same result as one full run' do
      expect(fixture.counts).to eq(fixture::FULL_RUN_COUNTS)
    end
  end

  context 'with aetc:cleanup' do
    before(:all) do
      fixture.build
      fixture.migrate('users')
    end

    it 'never offers a schema the tool did not create' do
      config, terminal, schemas = fixture.tool
      cleanup = AetcMigration::Cleanup.new(config: config, terminal: terminal, schemas: schemas)
      expect { cleanup.call(only: fixture::TARGET) }.to raise_error(AetcMigration::Error, /not a schema created by this tool/)
    end

    it 'keeps the schema unless its exact name is typed' do
      config, terminal, schemas = fixture.tool(answers: ['aetc_test'])
      AetcMigration::Cleanup.new(config: config, terminal: terminal, schemas: schemas).call(only: fixture::TRACKING)
      expect(schemas.exists?(fixture::TRACKING)).to be(true)
    end

    it 'exports id_map and migration_log, then drops the schema, when the name is typed' do
      config, terminal, schemas = fixture.tool(answers: [fixture::TRACKING])
      AetcMigration::Cleanup.new(config: config, terminal: terminal, schemas: schemas).call(only: fixture::TRACKING)
      expect(schemas.exists?(fixture::TRACKING)).to be(false)
      exported = Dir[config.log_dir.join('aetc_migration', "#{fixture::TRACKING}-*", '*.csv').to_s].map { |f| File.basename(f) }
      expect(exported).to contain_exactly('id_map.csv', 'migration_log.csv')
    end
  end
end
