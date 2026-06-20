# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tempfile'
require_relative '../../lib/database_sql_importer'

RSpec.describe DatabaseSqlImporter do
  let(:config) do
    {
      host: 'tidb.example.test',
      port: 4000,
      username: 'mahis',
      password: 'secret',
      database: 'mahis',
      connect_timeout: 12,
      ssl_mode: 'verify_identity',
      sslca: '/certs/ca.pem',
      variables: { sql_mode: 'STRICT_TRANS_TABLES' }
    }
  end

  it 'builds a TLS-enabled command without putting the password in argv' do
    importer = described_class.new(config: config, file_path: __FILE__, mysql_client: 'mysql')

    expect(importer.mysql_command).to include(
      '--host', 'tidb.example.test', '--port', '4000',
      '--ssl-mode=VERIFY_IDENTITY', '--ssl-ca=/certs/ca.pem', 'mahis'
    )
    expect(importer.mysql_command.join(' ')).not_to include('secret')
    expect(importer.mysql_environment).to eq('MYSQL_PWD' => 'secret')
  end

  it 'prefers a versioned MySQL 8 client when it is installed' do
    allow(File).to receive(:executable?).and_return(false)
    allow(File).to receive(:executable?)
      .with('/opt/homebrew/opt/mysql-client@8.4/bin/mysql')
      .and_return(true)

    importer = described_class.new(config: config, file_path: __FILE__)

    expect(importer.mysql_command.first).to eq('/opt/homebrew/opt/mysql-client@8.4/bin/mysql')
  end

  it 'only enables force mode when explicitly requested' do
    normal = described_class.new(config: config, file_path: __FILE__, mysql_client: 'mysql')
    forced = described_class.new(
      config: config,
      file_path: __FILE__,
      continue_on_error: true,
      mysql_client: 'mysql'
    )

    expect(normal.mysql_command).not_to include('--force')
    expect(forced.mysql_command).to include('--force')
  end

  it 'omits only the marked routine section when importing for TiDB' do
    sql = <<~SQL
      CREATE TABLE patients (id bigint primary key);
      -- Dumping routines for database 'mahis'
      CREATE FUNCTION patient_outcome() RETURNS INT RETURN 1;
      -- Final view structure for view `patients_view`
      CREATE VIEW patients_view AS SELECT id FROM patients;
    SQL

    Tempfile.create(['tidb-import', '.sql']) do |file|
      file.write(sql)
      file.flush
      importer = described_class.new(config: config, file_path: file.path, skip_routines: true)
      output = StringIO.new

      importer.send(:write_sql, output)

      expect(output.string).to include('CREATE TABLE patients')
      expect(output.string).not_to include('CREATE FUNCTION patient_outcome')
      expect(output.string).to include('CREATE VIEW patients_view')
    end
  end
end
