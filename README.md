# MaHIS Backend

## Requirements

### System Requirements

- **Ruby**: ~> 3.2.0
- **Rails**: ~> 7.0.6
- **Database**: MySQL/MariaDB
- **Redis**: For background jobs and caching
- **Node.js**: For JavaScript runtime
- **NPM**: For package management

### Dependencies

- **Web Server**: Puma (~> 6.3)
- **Background Jobs**: Sidekiq with Sidekiq-cron
- **Database Driver**: mysql2 gem
- **Authentication**: JWT (Json Web Token)

### 1. Clone the Repository

```bash
git clone https://github.com/Kuunika/MaHIS-Core.git mahis_backend
cd mahis_backend
```

### 2. Install Dependencies

```bash
bundle install
```

### 3. Configure Application

Copy all example configuration files:

```bash
cp config/database.yml.example config/database.yml
cp config/application.yml.example config/application.yml
```

Edit the configuration files with your settings:

- `config/database.yml` - Database credentials
- `config/application.yml` - Application settings

Edit `config/application.yml` with your application settings.

## Database Initialization

### For Empty Database

To initialize a new empty database:

```bash
rails db:create
INITIAL_SETUP=true rails db:seed
```

The `INITIAL_SETUP=true` environment variable ensures proper initialization of the database with all required seed data.

## Running the Application

### Development Mode

```bash
rails server
```

## Bulk MaHIS User Creation

Create a local config file and fill in the target instance, admin username, admin password, and Excel path:

```bash
cp config/users.yml.example config/users.yml
```

Put the Excel workbook for test at:

```bash
data/mahistest-users.xlsx
```

Put the Excel workbook for production at:

```bash
data/mahis-users.xlsx
```

The location columns in the workbook are `district` and `facility`. The importer reads `phone_number` and stores it as the user's Cell Phone Number person attribute.

Separate multiple roles, programs, or activities with a comma, semicolon, pipe, slash, or line break. For example:

```text
Clinician | Provider
OPD | HIV | NCD
```

Use the optional `activities` column to assign workflow activities, for example:

```text
Clinical Assessment,Investigations,Diagnosis,Treatment
```

The importer stores activities as user properties. It writes `Activities` from the `activities` column. For OPD, NCD, and AETC users, it also writes `OPD_activities`, `NCD_activities`, or `AETC_activities`; use optional workbook columns named `opd_activities`, `ncd_activities`, and `hiv_activities` when those program-specific values should differ from the general `activities` value.

When activity columns are blank, the importer automatically assigns role-based defaults for OPD, NCD, and HIV users. It also writes OPD dashboard access to `OPD_waiting_list`; override that with an optional `opd_waiting_list` workbook column when needed.

The optional `waiting_list_access` column accepts `yes/no`, `true/false`, or `1/0`.

The admin credentials are the MaHIS login credentials for `target_url`; the task logs in through the target instance API and does not use those credentials against your local Rails database.

Run a dry-run first:

```bash
rails 'mahis:users:create[test,true]'
```

Then run the actual import:

```bash
rails 'mahis:users:create[test]'
```

For production, dry-run first and then confirm the actual import when prompted:

```bash
rails 'mahis:users:create[production,true]'
rails 'mahis:users:create[production]'
```

The import reads every worksheet in the workbook. Each worksheet must have the same header row format; row log entries include the sheet name, such as `row=OPD:7`. It skips duplicate usernames that appear more than once in the workbook, validates roles/programs/district/facility records against the target MaHIS instance, creates missing users through the target backend API, and updates assignments, phone number, and properties for matching existing users at the expected facility. It writes a detailed log to `log/mahis-user-import-YYYYMMDD-HHMMSS.log`. Passwords are never printed in terminal output or import logs.

`target_url` is shown in the import and production confirmation output so operators can verify they are working against the intended instance.

## OFFLINE

# sync all records with couchDB

- rails sync:all # enqueue reference data and only missing patient documents + live dashboard
- rails "sync:all[rebuild_patients]" # rebuild every eligible patient document
- rails sync:progress # watch an already-running sync from another terminal
- WATCH=0 rails sync:all # enqueue only, no dashboard
- rails sync:doctor # check for common issues

By default, `rails sync:all` checks the type-3 patient identifiers against
CouchDB and enqueues only documents that are missing. It does not rebuild or
rewrite patient documents that already exist. Patients without a nonblank,
non-voided type-3 identifier are excluded because that identifier is used as the
CouchDB document ID. When a patient has multiple valid type-3 identifiers, the
newest one is the canonical document ID; older identifiers do not create extra
documents. Patient progress is measured against distinct canonical document
IDs, not every identifier row or every row in the MySQL patient table.

Use the explicit `rebuild_patients` argument only when existing CouchDB patient
documents must be regenerated, such as after importing historical clinical data:

```bash
rails "sync:all[rebuild_patients]"
```

This full mode rebuilds every eligible patient's complete record and can take
substantially longer than the default missing-only sync.

Patient bulk requests are split at 5 MiB so one large record cannot prevent the
other documents in its batch from syncing. Single patient documents are not
rejected by application-level observation, order, or serialized-size limits.
CouchDB, a reverse proxy, or available server memory may still impose practical
limits on unusually large documents.

The read-only threshold report lists patients above the former safeguards:

```bash
# Complete report. This serializes every eligible patient document and may take
# a long time on a large database.
rails patient_sync:threshold_report

# Check selected patients only.
PATIENT_IDS=149537,1577 rails patient_sync:threshold_report

# Faster: check counts and serialize only patients already above a count limit.
DOCUMENT_SCAN=candidates rails patient_sync:threshold_report

# Counts only; do not build patient documents.
DOCUMENT_SCAN=none rails patient_sync:threshold_report
```

The default CSV is `tmp/patient_sync_threshold_report.csv`. Set `OUTPUT` to
choose another path. The count columns include voided rows so they match the
historical checks exactly. Document build failures are written to a neighboring
`*_errors.csv` file and should be reviewed because their size could not be
determined.

### Parallel duplicate clinical-data cleanup

The duplicate cleanup runs synchronously unless `ASYNC=1` is supplied. Parallel
mode enqueues one patient per Sidekiq job on the dedicated
`clinical_data_cleanup` queue. Start a worker for that queue with:

```bash
bundle exec sidekiq -C config/sidekiq_clinical_data_cleanup.yml
```

The dedicated worker defaults to three concurrent patient cleanups. Adjust it
carefully when the database has sufficient capacity:

```bash
CLINICAL_DATA_CLEANUP_CONCURRENCY=4 \
  bundle exec sidekiq -C config/sidekiq_clinical_data_cleanup.yml
```

After reviewing the synchronous dry run, enqueue the confirmed cleanup:

```bash
PATIENT_IDS=149550,149564,149583 \
MODE=replay \
APPLY=1 \
CONFIRM=VOID_DUPLICATES \
VOIDED_BY=1 \
ASYNC=1 \
bin/rails clinical_data:deduplicate
```

Every job handles one patient transaction and enqueues the cleaned patient
document for rebuilding. It does not create filesystem backups. Duplicate rows
remain in MySQL with `voided`, `voided_by`, `date_voided`, and `void_reason`
audit fields. Rerunning an already completed patient is safe: only active
duplicate rows are selected, so applied rows are not voided again.

Before processing a large list, apply the cleanup performance indexes:

```bash
bin/rails db:migrate
```

The write phase loads duplicate-to-keeper IDs into connection-local temporary
tables and uses joined updates, avoiding hundreds of repeated `CASE` updates
over the same patient's rows.

# Run only one sync job

- rails "sync:run[StageSyncJob]"
- rails "sync:run[DdeIdsSyncJob]" # DDE IDs for all DDE-activated facilities
- rails "sync:run[DdeIdsSyncJob,100,800]" # DDE IDs for one facility location_id

# Start all listeners

- rails couchdb:start_all_listeners

# Production mode
- RAILS_ENV=production RACK_ENV=production bin/rails couchdb:start_all_listeners

---

## Data Migration from BHT-EMR to MaHIS

### Overview

The migration tool (`bin/emr_to_mahis_migrator.rb`) facilitates migrating patient data from a decentralized BHT-EMR database to the MaHIS centralized harmonized database. The migration supports:

- **Parallel processing** for optimal performance
- **Automatic location mapping** using facility codes
- **Concept ID mapping** for data harmonization
- **Incremental migration** with cache management
- **Test mode** for validation

### Prerequisites

Before running the migration, ensure:

1. **Source Database** - BHT-EMR database accessible from the server
2. **Target Database** - MaHIS database initialized with seed data
3. **Required Files**:
   - `db/locations_x_facilities.csv` - Facility code mapping
   - `db/concept_id_mapping.json` - Concept ID mapping (included in repository)
4. **System Resources**:
   - Adequate RAM (minimum 4GB recommended)
   - Sufficient disk space for both databases
   - Multiple CPU cores for parallel processing

### Configuration

#### 1. Database Configuration

Add the source database configuration to `config/database.yml`:

```yaml
centralized_source_db:
  adapter: mysql2
  encoding: utf8
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  reconnect: true
  database: emr_source_database_name
  host: localhost
  username: root
  password: your_password
```

#### 2. Verify Location Mapping

Ensure `db/locations_x_facilities.csv` contains the mapping between source location IDs and facility codes:

```csv
location_id,facility_code,facility_name
123,FAC001,Example Health Center
456,FAC002,District Hospital
```

### Running the Migration

#### Normal Migration Mode

```bash
bundle exec rails runner bin/emr_to_mahis_migrator.rb
```

The script will:

1. **Validate location** - Automatically map source location to target location
2. **Prepare database** - Remove constraints that may block migration
3. **Process tables** - Migrate data in parallel with optimized batch sizes
4. **Show progress** - Display real-time migration statistics

After a successful migration, the migrator automatically enqueues CouchDB rebuilds
only for patients belonging to the source database being migrated. It waits until
all migration groups and post-processing finish before enqueueing, so patient
documents include the migrated encounters, observations, orders, and program data.

The targeted rebuild requires Redis and a Sidekiq worker processing the
`batch_sync` and `patient_sync` queues. Monitor Sidekiq logs while the queued
patient batches drain.

To skip automatic enqueueing for an operational reason, run the migration with
`SKIP_COUCHDB_SYNC=true`.

The full rebuild remains available as a recovery command:

```bash
rails sync:patients_full
```

#### Test Mode

To test the migration with a limited dataset (10 records per table):

```bash
TEST_MODE=true bundle exec rails runner bin/emr_to_mahis_migrator.rb
```

#### Auto-Confirm Mode

To skip manual location confirmation (useful for scripted migrations):

```bash
AUTO_CONFIRM=true bundle exec rails runner bin/emr_to_mahis_migrator.rb
```

### Migration Features

#### Automatic Location Detection

The migration automatically determines the target location through:

1. Reading `current_health_center_id` from source database
2. Looking up facility code in `locations_x_facilities.csv`
3. Finding target location ID using facility code attribute
4. Confirming location with operator (unless `AUTO_CONFIRM=true`)

#### Intelligent Batch Processing

- **Dynamic batch sizing** based on table size and available memory
- **Adaptive thread count** based on CPU and memory usage
- **Progress tracking** with percentage completion
- **Automatic optimization** for different entity types

#### Cache Management

The migration maintains caches for:

- **User ID mapping** - Maps source user IDs to target IDs
- **Person ID mapping** - Maps source person IDs to target IDs
- **Encounter ID mapping** - Maps source encounter IDs to target IDs
- **Order ID mapping** - Maps source order IDs to target IDs
- **Program ID mapping** - Maps source program IDs to target IDs

Cache files are stored in `log/users_mapping_{location_id}.json`.

### Monitoring Migration

During migration, monitor:

```
Processing Table: encounter | Threads: 7 | CPU: 45.23% | RAM: 62.18% | Free RAM: 2.45 GB

Progress: ████████████████████░░░░ 78.5% (15234/19400)
Elapsed: 5m 23s | ETA: 1m 32s | Speed: 47.3 records/sec
```

### Post-Migration Steps

After successful migration:

1. **Verify Data Integrity**

```bash
# Check record counts
SELECT COUNT(*) FROM person;
SELECT COUNT(*) FROM encounter;
SELECT COUNT(*) FROM obs;

# Verify patients have correct location
SELECT COUNT(*) FROM patient_program WHERE location_id = YOUR_LOCATION_ID;
```

2. **Rebuild Indexes** (if needed)

```bash
# Restore indexes that were dropped
ALTER TABLE global_property ADD PRIMARY KEY (property);
ALTER TABLE drug_ingredient ADD PRIMARY KEY (concept_id, ingredient_id);
```

3. **Generate Reports**

```bash
# Test cohort report generation
bundle exec rails console
> ArtService::Reports::ArtCohort.new(
    name: 'Test Report',
    type: ReportType.find_by(name: 'Cohort'),
    start_date: Date.today.beginning_of_quarter,
    end_date: Date.today
  ).build_report
```

### Troubleshooting

#### Location Not Found

If automatic location detection fails:

```
✗ Error: Location ID 123 not found in locations_x_facilities.csv
Falling back to manual entry...
```

**Solution**:

- Verify facility is in `db/locations_x_facilities.csv`
- Check facility code attribute exists in location_attributes table
- Manually enter location ID when prompted

#### Memory Issues

If migration runs out of memory:

```
GC::OutOfMemory: Cannot allocate memory
```

**Solution**:

- Reduce batch size by setting smaller values
- Reduce thread count
- Add swap space
- Process tables one at a time

#### Foreign Key Constraints

```
MySQL2::Error: Cannot delete or update a parent row: a foreign key constraint fails
```

**Solution**: The `prepare_centralized_db` function automatically handles this, but if issues persist:

```sql
-- Temporarily disable foreign key checks
SET FOREIGN_KEY_CHECKS = 0;
-- Run migration
-- Re-enable
SET FOREIGN_KEY_CHECKS = 1;
```

### Performance Optimization

For optimal migration performance:

1. **Run during off-peak hours** to maximize available resources
2. **Use local database connections** to reduce network latency
3. **Ensure adequate RAM** (8GB+ recommended for large datasets)
4. **Use SSD storage** for faster I/O operations
5. **Close unnecessary applications** to free resources

### Migration Tables Processing Order

The migration processes tables in this order:

1. **Core entities**: person, patient, users, patient_identifiers
2. **Clinical data**: encounter, obs, orders, drug_orders
3. **Program data**: patient_program, patient_state
4. **Supporting data**: location, concept, users_roles
5. **Configuration**: global_property

Non-reset tables (preserved between migrations):

- Patient, DrugOrder, GlobalProperty, UserRole, UserProperty
- DrugIngredient, LimsAcknowledgementStatus

### Best Practices

1. **Always run in TEST_MODE first** to validate the migration
2. **Back up both databases** before starting migration
3. **Monitor system resources** during migration
4. **Keep log files** for troubleshooting
5. **Verify data** after migration before going live
6. **Document any customizations** made to the migration script

---
