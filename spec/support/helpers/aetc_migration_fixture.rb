# frozen_string_literal: true

require 'tmpdir'

# Throwaway schemas for spec/services/aetc_migration_spec.rb:
#   aetc_test_src           a small AETC database (spec/fixtures/aetc_migration/aetc_schema.sql + the rows below)
#   aetc_test_tgt           empty copies of the MaHIS tables the migration writes, taken from the test database
#   aetc_test_src_migration the tracking schema the tool creates for aetc_test_src
# The test database itself is only read (for the table structure), never written.
module AetcMigrationFixture
  SOURCE = 'aetc_test_src'
  TARGET = 'aetc_test_tgt'
  TRACKING = "#{SOURCE}_migration".freeze
  TARGET_TABLES = %w[users role user_role user_programs person person_name person_address person_attribute patient
                     patient_identifier relationship visit encounter obs orders order_extension
                     lab_lims_order_mappings].freeze
  T0 = '2024-01-01 08:00:00'
  # Target rows after a full run. person: 5 AETC persons, the migration user's person and MaHIS person 2;
  # orders and lab_lims_order_mappings include the MaHIS rows seeded by seed_target.
  FULL_RUN_COUNTS = {
    'users' => 7, 'role' => 2, 'user_role' => 2, 'user_programs' => 3, 'person' => 8, 'person_name' => 5, 'person_address' => 4, 'person_attribute' => 2,
    'patient' => 3, 'patient_identifier' => 5, 'relationship' => 2, 'visit' => 3, 'encounter' => 7, 'obs' => 15,
    'orders' => 5, 'order_extension' => 1, 'lab_lims_order_mappings' => 2
  }.freeze

  module_function

  def db
    ActiveRecord::Base.connection
  end

  def build
    drop
    template = db.current_database
    db.execute("CREATE DATABASE #{SOURCE} CHARACTER SET utf8mb3")
    sql_statements(Rails.root.join('spec/fixtures/aetc_migration/aetc_schema.sql')).each do |statement|
      db.execute(statement.sub(/\ACREATE TABLE `/, "CREATE TABLE `#{SOURCE}`.`"))
    end
    db.execute("CREATE DATABASE #{TARGET}")
    TARGET_TABLES.each { |t| db.execute("CREATE TABLE #{TARGET}.#{t} LIKE #{db.quote_table_name(template)}.#{t}") }
    seed_target
    seed_source
  end

  def drop
    [SOURCE, TARGET, TRACKING].each { |schema| db.execute("DROP DATABASE IF EXISTS #{schema}") }
    FileUtils.rm_rf(@root) if @root
    @root = nil
  end

  # The folder the tool writes its log and CSV files to during a spec (removed by drop).
  def root
    @root ||= Dir.mktmpdir('aetc-migration-spec')
  end

  # Config, terminal and schemas pointing the tool at the fixture schemas. Output goes to a StringIO.
  def tool(answers: [])
    env = { 'AETC_SOURCE_DB' => SOURCE, 'AETC_MAPPINGS_DIR' => Rails.root.join('db/aetc_migration/mappings').to_s }
    config = AetcMigration::Config.new(
      env: env, root: root,
      db_config: ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: TARGET)
    )
    terminal = AetcMigration::Terminal.new(output: StringIO.new, input: StringIO.new(answers.map { |a| "#{a}\n" }.join),
                                           color: false)
    [config, terminal, AetcMigration::Schemas.new(config: config)]
  end

  # rake aetc:migrate (without aetc:check, which also validates the MaHIS metadata the mappings point at).
  def migrate(step = nil, dry_run: false, limit: nil)
    config, terminal, schemas = tool
    AetcMigration::Tracking.for(SOURCE, config: config, schemas: schemas).save_setting('check_passed_at', 'spec')
    AetcMigration::Runner.new(config: config, terminal: terminal, schemas: schemas, dry_run: dry_run,
                              limit: limit).call(step)
    terminal.output.string
  end

  def counts
    TARGET_TABLES.index_with { |t| db.select_value("SELECT COUNT(*) FROM #{TARGET}.#{t}").to_i }
  end

  # Rows from a query; tgt. and trk. stand for the target and tracking schemas.
  def query(sql)
    db.select_all(sql.gsub('tgt.', "#{TARGET}.").gsub('trk.', "#{TRACKING}.")).to_a
  end

  def logged(reason)
    query("SELECT entity, src_id FROM trk.migration_log WHERE reason = #{db.quote(reason)} ORDER BY entity, src_id")
      .map { |r| [r['entity'], r['src_id']] }
  end

  def sql_statements(path)
    File.read(path).gsub(/^--.*$/, '').split(/;\s*$/).map(&:strip).reject(&:empty?)
  end

  def ins(table, **row)
    db.execute("INSERT INTO #{table} (#{row.keys.join(', ')}) VALUES (#{row.values.map { |v| db.quote(v) }.join(', ')})")
  end

  # MaHIS rows that clash with AETC rows (the target tables have no foreign keys, so no metadata is needed).
  def seed_target
    ins("#{TARGET}.users", user_id: 1, system_id: 'admin', username: 'admin', creator: 1, uuid: 't-user-1')
    ins("#{TARGET}.users", user_id: 2, system_id: 'nurse', username: 'nurse', creator: 1, uuid: 't-user-2')
    ins("#{TARGET}.users", user_id: 3, system_id: 'nurse_aetc', username: 'nurse_aetc', creator: 1, uuid: 't-user-3')
    %w[Clinician Provider].each { |role| ins("#{TARGET}.role", role: role, description: role, uuid: "t-role-#{role}") }
    ins("#{TARGET}.person", person_id: 2, creator: 1, date_created: T0, uuid: 's-person-106') # same uuid as AETC 106
    ins("#{TARGET}.orders", order_id: 1, order_type_id: 6, concept_id: 58_110, orderer: 1, creator: 1, date_created: T0,
                            patient_id: 1, accession_number: 'XBL0001', uuid: 't-order-1')
    ins("#{TARGET}.lab_lims_order_mappings", lims_id: 'LIMSDUP', order_id: 1, created_at: T0, updated_at: T0)
  end

  def seed_source
    seed_people
    seed_identifiers_and_relationships
    seed_clinical
    seed_orders
  end

  def person(pid, gender, voided: 0)
    ins("#{SOURCE}.person", person_id: pid, gender: gender, birthdate: '1990-05-01', creator: 88, date_created: T0,
                            voided: voided, uuid: "s-person-#{pid}")
  end

  def name(nid, pid, given, family, voided: 0, preferred: 0, created: T0)
    ins("#{SOURCE}.person_name", person_name_id: nid, person_id: pid, given_name: given, family_name: family,
                                 voided: voided, preferred: preferred, creator: 88, date_created: created,
                                 uuid: "s-name-#{nid}")
  end

  def addr(aid, pid, preferred: 0, voided: 0, created: T0, **cols)
    ins("#{SOURCE}.person_address", person_address_id: aid, person_id: pid, preferred: preferred, voided: voided,
                                    creator: 88, date_created: created, uuid: "s-addr-#{aid}", **cols)
  end

  def attr(aid, pid, type_id, value, voided: 0)
    ins("#{SOURCE}.person_attribute", person_attribute_id: aid, person_id: pid, value: value,
                                      person_attribute_type_id: type_id, creator: 88, date_created: T0,
                                      voided: voided, uuid: "s-attr-#{aid}")
  end

  def seed_people
    person(900, 'Male') # only a user: migrated as the user's person
    ins("#{SOURCE}.users", user_id: 88, system_id: '88-1', username: 'hdumira', creator: 1, date_created: T0,
                           person_id: 900, uuid: 's-user-88')
    ins("#{SOURCE}.users", user_id: 89, system_id: 'admin', username: 'admin', creator: 1, date_created: T0,
                           person_id: 102, uuid: 's-user-89')   # username taken in MaHIS -> admin_aetc
    ins("#{SOURCE}.users", user_id: 90, system_id: 'nurse', username: 'nurse', creator: 1, date_created: T0,
                           person_id: 104, uuid: 's-user-90')   # nurse and nurse_aetc taken -> nurse_aetc2
    ins("#{SOURCE}.user_role", user_id: 88, role: 'Clinician')
    ins("#{SOURCE}.user_role", user_id: 88, role: 'Patient Attendant') # not a MaHIS role -> logged
    ins("#{SOURCE}.user_role", user_id: 89, role: 'Provider')

    person(101, 'Male') # active patient
    ins("#{SOURCE}.patient", patient_id: 101, creator: 88, date_created: T0)
    name(1, 101, 'Old', 'Name', voided: 1, preferred: 1)
    name(2, 101, 'John', 'Banda')
    addr(1, 101, preferred: 1, address1: 'Blantyre', address2: 'Chigayo', address3: 'Zomba', city_village: 'TA Kapeni',
                 state_province: 'TA Mwambo', county_district: 'TA Kapeni', country: 'Malawian')
    addr(2, 101, address1: 'Mbayani', address2: 'N/A', city_village: 'TA Machinjili')
    attr(1, 101, 12, '0999000111')
    attr(2, 101, 25, '0888000222')
    attr(3, 101, 39, 'N/A')                         # empty value -> skipped
    attr(4, 101, 12, '0999999999', voided: 1)       # voided, owner active -> skipped

    person(102, nil) # guardian, no name
    person(103, 'N/A') # voided patient -> brings its voided rows
    ins("#{SOURCE}.patient", patient_id: 103, creator: 88, date_created: T0, voided: 1, voided_by: 88)
    name(3, 103, 'Void', 'Patient', voided: 1, preferred: 1)
    addr(3, 103, preferred: 1, voided: 1, address1: 'Thyolo', address3: 'Thyolo', county_district: 'TA Nsabwe')

    person(104, 'F') # not a patient; 4 addresses, 2 active names
    name(4, 104, 'Mary', 'Phiri', preferred: 1, created: '2023-01-01 00:00:00')
    name(5, 104, 'Mary', 'Tembo', created: '2024-06-01 00:00:00')
    addr(4, 104, preferred: 1, created: '2023-01-01 00:00:00', address1: 'Old', address3: 'Old', county_district: 'Old')
    addr(5, 104, preferred: 1, created: '2024-06-01 00:00:00', address1: 'Mwanza', address3: 'Neno',
                 county_district: 'TA Kanduku')
    addr(6, 104, created: '2023-01-01 00:00:00', address1: 'OldVillage', city_village: 'Old TA')
    addr(7, 104, created: '2024-06-01 00:00:00', address1: 'Kunenekude', city_village: 'TA Chikowi')

    person(105, 'M') # empty address + unmapped country
    addr(8, 105, preferred: 1, address1: 'N/A', address2: 'N/A', city_village: 'N/A')
    addr(9, 105, preferred: 1, address1: 'Lilongwe', address3: 'Lilongwe', county_district: 'TA Kalumbu',
                 country: 'Atlantean')
    ins("#{SOURCE}.patient", patient_id: 105, creator: 88, date_created: T0)

    person(106, 'F') # uuid already in MaHIS -> not migrated
  end

  def ident(iid, pid, type_id, value, location: 614, voided: 0, preferred: 0)
    ins("#{SOURCE}.patient_identifier", patient_identifier_id: iid, patient_id: pid, identifier: value,
                                        identifier_type: type_id, location_id: location, voided: voided,
                                        preferred: preferred, creator: 88, date_created: T0, uuid: "s-pi-#{iid}")
  end

  def rel(rid, person_a, type_id, person_b, voided: 0)
    ins("#{SOURCE}.relationship", relationship_id: rid, person_a: person_a, relationship: type_id, person_b: person_b,
                                  creator: 88, date_created: T0, voided: voided, uuid: "s-rel-#{rid}")
  end

  def seed_identifiers_and_relationships
    ident(1, 101, 3, 'NPID01', preferred: 1)         # National id -> 2
    ident(2, 101, 8, '103VWY7')                      # Dummy ID -> skipped
    ident(3, 101, 27, 'dde-doc-101', location: 299)  # DDE doc id, Limbe -> 676
    ident(4, 101, 3, 'NPIDOLD', voided: 1)           # voided, patient active -> skipped
    ident(5, 101, 3, 'DUP1')                         # shared with 105 -> loaded + flagged
    ident(6, 105, 3, 'DUP1')
    ident(7, 105, 28, 'MW123', location: 999)        # unmapped location
    ident(8, 103, 3, 'NPID03', voided: 1)            # voided patient -> brought as voided
    ins("#{SOURCE}.patient", patient_id: 107, creator: 88, date_created: T0) # no person -> skipped

    rel(1, 101, 6, 102)
    rel(2, 101, 2, 104)                              # Sibling -> 30
    rel(3, 101, 6, 555)                              # person 555 doesn't exist -> dangling
    rel(4, 101, 18, 102)                             # type 18 -> skipped
    rel(5, 101, 6, 106)                              # person 106 not migrated -> skipped
    rel(6, 101, 6, 104, voided: 1)                   # voided, owners active -> skipped
  end

  def visit(vid, pid, loc: 614, voided: 0, stopped: nil)
    ins("#{SOURCE}.visit", visit_id: vid, patient_id: pid, visit_type_id: 1, date_started: T0, date_stopped: stopped,
                           location_id: loc, creator: 88, date_created: T0, voided: voided, uuid: "s-visit-#{vid}")
  end

  def enc(eid, pid, etype, vid, loc: 614, voided: 0)
    ins("#{SOURCE}.encounter", encounter_id: eid, encounter_type: etype, patient_id: pid, location_id: loc,
                               encounter_datetime: T0, creator: 88, date_created: T0, voided: voided, visit_id: vid,
                               uuid: "s-enc-#{eid}")
  end

  def obs(oid, pid, eid, concept, voided: 0, group: nil, **value)
    ins("#{SOURCE}.obs", obs_id: oid, person_id: pid, concept_id: concept, encounter_id: eid, obs_datetime: T0,
                         location_id: 614, obs_group_id: group, creator: 88, date_created: T0, voided: voided,
                         uuid: "s-obs-#{oid}", **value)
  end

  def seed_clinical
    visit(1, 101)                                    # open visit stays open
    visit(2, 101, voided: 1, stopped: T0)            # voided, patient active -> skipped
    visit(3, 103, voided: 1, stopped: T0)            # voided patient -> migrated voided
    visit(4, 105, loc: 1, stopped: T0)               # "Unknown" location
    enc(1, 101, 6, 1)                                # VITALS -> 6
    enc(2, 101, 122, 1, loc: 299)                    # PRESENTING COMPLAINTS -> 109, Limbe -> 676
    enc(3, 101, 999, 1)                              # unmapped encounter type -> skipped
    enc(4, 101, 6, 1, voided: 1)                     # voided, patient active -> skipped
    enc(5, 103, 6, 3, voided: 1)                     # voided patient -> migrated voided
    enc(6, 105, 6, 4, loc: 1)                        # "Unknown" location -> 1291 (QECH)
    enc(7, 101, 6, 2)                                # its visit was not migrated -> no visit
    obs(1, 101, 1, 5242, value_text: '18')           # copied as it is
    obs(2, 101, 2, 10_820, value_coded: 1065)        # coded answer Yes -> 37966
    obs(3, 101, 1, 5088)                             # group parent
    obs(4, 101, 1, 5085, group: 3, value_numeric: 120) # child of 3
    obs(5, 101, 1, 12_772, value_text: 'Negative')   # text -> coded 37452
    obs(6, 101, 1, 12_762, value_text: 'nil')        # lab test stored as text: text kept as it is
    obs(7, 101, 1, 12_533, value_text: '3')          # concept with no MaHIS match -> skipped
    obs(8, 101, 3, 5242, value_text: '20')           # encounter not migrated -> skipped
    obs(9, 101, 1, 10_820, value_coded: 4)           # answer with no MaHIS match -> kept as text
    obs(10, 101, 1, 5242, value_text: '22', voided: 1) # voided, patient active -> skipped
    obs(11, 103, 5, 5242, value_text: '16', voided: 1) # voided patient -> migrated voided
    obs(12, 101, 1, 12_772, value_text: 'Positive')  # not in the value map -> kept as text
    obs(15, 101, 1, 12_772, value_text: "  Negative \n") # surrounding whitespace is ignored -> 37452
    obs(16, 101, 1, 12_772, value_text: "Neg#{' ' * 5000}ative") # long run of spaces (regexp_time_limit)
    obs(17, 101, 1, 12_762, value_numeric: 4.3)      # lab test stored as text: the number becomes '4.3'
    obs(18, 101, 1, 11_701, value_text: '40.2')      # blood gas pCO2 -> MaHIS 48838 (mapped by id)
  end

  def order(oid, pid, eid, specimen, type_id: 4, voided: 0, **cols)
    ins("#{SOURCE}.orders", order_id: oid, order_type_id: type_id, concept_id: specimen, orderer: 88, encounter_id: eid,
                            creator: 88, date_created: T0, voided: voided, patient_id: pid, uuid: "s-order-#{oid}",
                            **cols)
  end

  def seed_orders
    enc(8, 101, 13, 1)                               # LAB -> 13
    enc(9, 103, 13, 3, voided: 1)                    # voided patient
    order(1, 101, 8, 12_744, start_date: '2024-01-01 08:00:00', accession_number: 'XAETC2400001',
                             comment_to_fulfiller: 'ANEMIC', discontinued: 1, discontinued_by: 14,
                             discontinued_date: '2024-02-01 10:00:00.700000',
                             discontinued_reason_non_coded: 'Sample drawn/updated')
    order(2, 101, 8, 1002, accession_number: 'Xtest243K1', order_number: 'Xtest243K1') # no start_date
    order(3, 101, 999, 12_744, start_date: T0)       # encounter doesn't exist -> skipped
    order(4, 101, 8, 99_999, start_date: T0)         # unmapped specimen -> skipped
    order(5, 101, 8, 12_744, start_date: T0, voided: 1) # voided, patient active -> skipped
    order(6, 103, 9, 12_744, start_date: T0, voided: 1, voided_by: 88) # voided patient -> migrated voided
    order(7, 101, 8, 12_744, start_date: T0, accession_number: 'XBL0001') # accession used in MaHIS -> flagged
    order(8, 101, 8, 12_744, start_date: T0, type_id: 1) # Drug Order -> skipped

    [[1, 1, 0], [2, 3, 0], [3, 2, 1]].each do |xid, oid, voided|
      ins("#{SOURCE}.order_extension", order_extension_id: xid, order_id: oid, value: 'LIMS', creator: 14,
                                       date_created: T0, voided: voided, created_at: T0, updated_at: T0)
    end
    [[1, 1, 'XAETC2400001'], [2, 2, 'LIMSDUP'], [3, 3, 'XAETC2400003']].each do |mid, oid, lims_id|
      ins("#{SOURCE}.lab_lims_order_mappings", id: mid, lims_id: lims_id, order_id: oid, pushed_at: T0, created_at: T0,
                                               updated_at: T0, revision: '0', result_push_status: 0)
    end
    obs(13, 101, 8, 5242, value_text: 'FBC', order_id: 1) # linked to order 1
    obs(14, 101, 8, 5242, value_text: 'RFT', order_id: 4) # its order is not migrated
  end
end
