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

The location columns in the workbook are `district` and `facility`.

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

The import reads the first worksheet, skips duplicate usernames that appear more than once in the workbook, validates roles/programs/district/facility records against the target MaHIS instance, creates missing users through the target backend API, and updates properties for matching existing users at the expected facility. It writes a detailed log to `log/mahis-user-import-YYYYMMDD-HHMMSS.log`. Passwords are never printed in terminal output or import logs.

`target_url` is shown in the import and production confirmation output so operators can verify they are working against the intended instance.

## OFFLINE

# sync all records with couchDB

- rails sync:all # enqueue everything + live dashboard
- rails sync:progress # watch an already-running sync from another terminal
- WATCH=0 rails sync:all # enqueue only, no dashboard
- rails sync:doctor # check for common issues

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
