# TiDB deployment

MAHIS supports TiDB 8.5 or newer through the existing `mysql2` adapter. TiDB 8.5 is the minimum because the MAHIS schema relies extensively on enforced foreign keys.

The TiDB schema bootstrap skips the stored-routine block without deleting it from the source dump. Reporting paths that called `date_antiretrovirals_started` and `patient_date_enrolled` now use a set-based fact table. The remaining stored-function families and legacy `CREATE TABLE ... AS SELECT` report paths are still deferred and must be ported before their reports can run on TiDB.

## Local migrated cluster

The repository includes a persistent, single-replica TiDB 8.5.6 cluster for development and migration validation. It is not a production topology.

The local TiKV profile is capped at 4 GiB with a 2 GiB strict block cache so a
bulk import does not consume the entire Docker Desktop VM. Production TiKV
memory sizing must be based on dedicated host capacity instead of this profile.

```bash
docker compose -f docker/tidb/compose.yml up -d
docker compose -f docker/tidb/compose.yml ps
```

Local endpoints:

- SQL: `127.0.0.1:4001`
- Status API: `http://127.0.0.1:10081/status`
- TiFlash metrics: `http://127.0.0.1:8234/metrics`
- Prometheus: `http://127.0.0.1:9090`
- Database: `mahis_dev`
- Application user: `mahis_app`
- Local-only password: `mahis_tidb_local`

The local `config/database.yml` points the development environment at this cluster. MySQL remains available on port `3306` as the source and rollback copy. Stop TiDB without deleting its data with:

```bash
docker compose -f docker/tidb/compose.yml down
```

Do not add `--volumes` unless the local TiDB database should be permanently deleted.

### Local monitoring

The Compose stack includes Prometheus with 15 days of persistent metrics for PD,
TiDB, TiKV, and TiFlash. The one-shot `monitoring-config` service automatically
registers Prometheus with PD so the built-in TiDB Dashboard can display
historical monitoring data. To repair that registration manually, run:

```bash
docker exec mahis-tidb-pd /pd-ctl -u http://127.0.0.1:2379 \
  config set pd-server.metric-storage http://prometheus:9090
```

Open TiDB Dashboard at `http://127.0.0.1:2379/dashboard/` and Prometheus at
`http://127.0.0.1:9090`. Confirm all scrape targets are healthy at
`http://127.0.0.1:9090/targets`.

On macOS, MySQL 9 clients cannot load TiDB's default `mysql_native_password` authentication plugin. Install the supported versioned client and compile `mysql2` against it:

```bash
brew install mysql-client@8.4
bundle config set --local build.mysql2 --with-mysql-config=/opt/homebrew/opt/mysql-client@8.4/bin/mysql_config
bundle pristine mysql2
```

The SQL importer automatically prefers this client path when it is installed. `MYSQL_CLIENT` can override it.

### Migration result

The local `mahis_dev` snapshot migrated on 2026-06-20 with these checks:

- 207 source and target base tables
- 478,504 source and target rows, compared table by table with no mismatches
- 350 foreign keys
- 29 working views
- 0 routines, intentionally deferred

These six views were restored by the ART reporting-facts migration and no longer call a stored function:

```text
earliest_start_date
guardians
patients_demographics
patients_on_arvs
patients_with_has_transfer_letter_yes
reason_for_eligibility_obs
```

The migrated snapshot currently contains no patients in ART state 7, so both the source function-backed view and the new fact-backed view correctly contain zero rows. Validate representative non-empty ART data before a production cutover.

The readiness check also reports 11 legacy tables without primary keys and five zero-date defaults. Those were preserved rather than rewriting table creation, as requested.

## Configuration

Copy `config/database.yml.example` to `config/database.yml`, then configure the application through environment variables:

```bash
export TIDB_ENABLED=true
export DB_HOST='gateway01.example.tidbcloud.com'
export DB_PORT=4000
export DB_NAME='mahis'
export DB_USERNAME='mahis_app'
export DB_PASSWORD='replace-me'
export DB_POOL=25
export DB_SSL_MODE='verify_identity'
export DB_SSL_CA='/etc/ssl/certs/ca-certificates.crt'
export TIDB_REQUIRE_TLS=true
```

For a trusted private, self-managed TiDB network without client TLS, explicitly set `DB_SSL_MODE=disabled` and omit `TIDB_REQUIRE_TLS`. Do not disable TLS for a public endpoint.

`DB_POOL` applies per process. Size the TiDB connection allowance for every Puma worker and Sidekiq process rather than treating the value as a deployment-wide total.

New TiDB clusters default to pessimistic transactions. If the readiness task reports another mode on a self-managed cluster, set it before serving application traffic:

```sql
SET GLOBAL tidb_txn_mode = 'pessimistic';
```

## Initialize a new database

Create the database and scoped user in TiDB first. The application user needs normal DML and DDL privileges during setup, including `REFERENCES`, `CREATE VIEW`, and `CREATE TEMPORARY TABLES`.

```bash
bundle exec rails db:migrate
INITIAL_SETUP=true bundle exec rails db:seed
bundle exec rails db:tidb:check
bundle exec rails db:tidb:tiflash:configure
TIMEOUT=600 bundle exec rails db:tidb:tiflash:wait
bundle exec rails db:tidb:reporting:refresh
```

The migration streams `db/mahis_skeleton.sql.gz` through the MySQL client. Set `MYSQL_CLIENT` when the executable is not named `mysql`. Import failures stop the migration instead of being reported as success. The importer remains fail-fast unless `continue_on_error` is explicitly enabled by a controlled migration that records deferred objects.

## TiFlash reporting

The local Compose stack includes one persistent TiFlash node. MAHIS creates TiFlash replicas only for the tables used by the first set-based ART reporting path; extend `TidbReporting::REPLICA_TABLES` as each additional report family is ported.

```bash
bundle exec rails db:tidb:tiflash:configure
TIMEOUT=600 bundle exec rails db:tidb:tiflash:wait
bundle exec rails db:tidb:tiflash:status
bundle exec rails db:tidb:reporting:refresh
```

`ReportingFactsRefreshJob` refreshes `reporting_patient_art_facts` every 15 minutes. The refresh enables and enforces TiFlash reads for the materializing `INSERT ... SELECT` session and restores all session settings afterward. Normal report jobs enable MPP but permit TiKV fallback while report families are still being ported. Set `TIDB_REPORTING_ENFORCE_MPP=true` for a fully replicated report when falling back should be treated as an error.

Confirm a report is actually using TiFlash with `EXPLAIN`. The plan should contain `mpp[tiflash]` tasks rather than only `cop[tikv]` tasks. Replica availability alone does not guarantee that the optimizer selected TiFlash.

One TiFlash node is useful for development but provides neither reporting high availability nor enough isolation for production. Deploy multiple TiFlash replicas across failure domains, size them for the replicated data and concurrent scans, and monitor replica progress and MPP query latency before directing production reports to them.

The next routine families to port are `disaggregated_age_group`, `patient_current_regimen`, and `patient_outcome`. They are deliberately not emulated with query-text rewriting; each should become a reviewed set-based expression or reporting fact with parity tests against representative MySQL results.

## Migrate an existing MySQL database

Use TiDB Data Migration for full plus incremental replication, or Dumpling and TiDB Lightning for a controlled offline import. Do not use `bin/emr_to_mahis_migrator.rb` as the transport for a whole production database.

For a maintenance-window migration where all source writers can remain stopped,
`bin/mysql_to_tidb_direct_dump.sh` creates a compressed snapshot, imports it into
an empty TiDB database, and compares exact row counts. It deliberately excludes
stored routines, triggers, and events. Run `bin/mysql_to_tidb_direct_dump.sh
--help` for its required environment variables. The target database is never
dropped or overwritten by the script. Copy `.env.tidb-migration.example` to
the ignored `.env.tidb-migration`, then run it with `ENV_FILE=.env.tidb-migration
bin/mysql_to_tidb_direct_dump.sh`. When `TARGET_ADMIN_USERNAME` is configured,
the script uses that account only to create the empty target database and grant
the scoped import user; otherwise, those privileges must already exist. The
local environment can set `LOCAL_TIFLASH_CONTAINER=mahis-tidb-tiflash` to pause
TiFlash during the bulk import and avoid exhausting Docker Desktop memory. Do
not set that option for production or non-Docker TiDB clusters. The default
`EXCLUDED_TABLE_DATA=immunization_cache_data` preserves that table's schema but
omits its rebuildable JSON cache rows, which can exceed TiDB's default 6 MiB
single-entry limit. Exact row verification reports this exclusion explicitly.
`STRIP_DEFINERS=true` removes source-only MySQL account clauses such as
`DEFINER=petros@localhost` from views while retaining their SQL and security
mode, avoiding a requirement for the TiDB import user to have `SUPER`.
The local environment enables `DROP_TARGET_ON_FAILURE=true` so a failed import
does not leave a partial database that blocks the next rehearsal. Keep this off
in production when the failed target must be retained for investigation.

1. Run a compatibility check against a production schema snapshot.
2. Import schema and data into a non-production TiDB cluster.
3. Run `rails db:migrate` and `rails db:tidb:check`.
4. Compare row counts and foreign-key relationships for every table.
5. Exercise login, patient registration, encounter saves, medication, stock, bed management, offline ingestion, and background jobs.
6. Load test representative reads and writes before cutover.
7. Use incremental replication or a write freeze for the final cutover, then retain the source as a rollback target.

The readiness task reports tables without primary keys and legacy zero-date defaults. These are warnings because changing them requires data-specific decisions; resolve them before high-volume production traffic.
