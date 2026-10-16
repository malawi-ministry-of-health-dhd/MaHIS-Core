# AETC → MaHIS-core migration

Rake tasks that copy the AETC OpenMRS database (patients, people, visits, encounters, lab orders and observations) into a MaHIS-core database.

- **Code:** `app/services/aetc_migration/`
- **Tasks:** `lib/tasks/aetc_migration.rake`
- **Mappings:** this folder

MaHIS metadata is primary. Every AETC id (concept, encounter type, location, …) is translated to its MaHIS id through the mapping files in `mappings/`. AETC rows that cannot be translated are skipped or flagged, and each one is recorded with a reason.

## Before you start

- **Fresh runs only.** The target MaHIS database must not already contain AETC data from an earlier migration. `aetc:check` refuses to continue if it does.
- **Back up MaHIS:** `mysqldump <mahis_db> > mahis_before_aetc.sql`. A live run commits as it goes; the only undo is restoring this backup.
- **Target database:** the one in `config/database.yml` for the current `RAILS_ENV`. `bin/rails aetc:config` shows what will be used.
- **Same MySQL server:** the AETC data must be on the same MySQL server, in its own schema, which you either restore yourself or load with `aetc:load`.

## Runbook

```bash
# 1. Get AETC onto the MySQL server. Either load the dump (creates aetc_YYYYMMDD):
bin/rails "aetc:load[/path/to/aetcdbprod.sql]"        # .sql or .sql.gz
#    ...or, if it is already restored, name its schema for every command below:
export AETC_SOURCE_DB=aetc_live_prod

# 2. Check everything: AETC tables, mapping files, the MaHIS ids they point at, unmapped AETC data
bin/rails aetc:check

# 3. Trial run on the first 1,000 persons, rolled back at the end
DRY_RUN=1 bin/rails aetc:migrate

# 4. The real run (each batch is committed; stop it any time and run it again to continue)
bin/rails aetc:migrate

# 5. Make the new patients searchable and visible in the frontend (see "After the run")
```

### Options

| Option | What it does |
|---|---|
| `bin/rails "aetc:migrate[obs]"` | Run one step: `users`, `persons`, `patients`, `relationships`, `visits`, `encounters`, `orders`, `obs` |
| `LIMIT=n` | Migrate only the next *n* AETC persons and their records; run again without `LIMIT` for the rest |
| `DRY_RUN=1` | Run inside one transaction and roll everything back. Defaults to `LIMIT=1000`. |
| `AETC_SOURCE_DB=<schema>` | The AETC schema to migrate from (otherwise the one `aetc:load` created) |
| `AETC_BATCH_SIZE=n` | Batch size: rows for the people steps, patients for the clinical steps (defaults: 500; visits 1,000, encounters/orders 500, obs 100) |
| `AETC_MAPPINGS_DIR=<dir>` | Use mapping files from another folder |
| `AETC_CREATOR_USER_ID=n` | MaHIS user recorded as the creator of the `aetc_migration` user (default 1) |
| `MYSQL_CLIENT=<path>` | `mysql` client used by `aetc:load` |

Write the variable before the command with no comma: `AETC_SOURCE_DB=aetc_live_prod bin/rails aetc:migrate`.

### How long it takes

The full AETC production data took 40 minutes on a laptop (MySQL 9.5, 8 GB buffer pool), in October 2026:

| Step | Time | Rows |
|---|---|---|
| Users | 1 s | 564 users |
| Persons, patients, relationships | 13 min | 322,876 persons, 153,708 patients, 168,562 relationships |
| Visits | 21 s | 169,393 visits |
| Encounters | 3.5 min | 2.1 million encounters |
| Lab orders | 1 min | 33,337 orders |
| Obs | 22 min | 9.4 million obs |

**Give MySQL enough memory first.** With the default 128 MB buffer pool the same run took nearly 2 hours: obs slows down as the table outgrows the cache. Both settings below apply without a restart and are kept after one:

```sql
SELECT @@innodb_buffer_pool_size / 1024 / 1024 / 1024 AS gb;   -- check
SET PERSIST innodb_buffer_pool_size = 8589934592;               -- 8 GB (about a quarter of the machine's memory)
SET PERSIST innodb_redo_log_capacity = 2147483648;              -- 2 GB of disk for the redo log
```

Also make sure nothing else is using the MySQL server during the run (for example a Sidekiq CouchDB rebuild).

## After the run

Migrated rows are written with plain SQL, so MaHIS callbacks did not run. Two follow-ups are needed before the patients show up in MaHIS:

```bash
# Name search index (person_name_code). The block is needed so that names from every location are indexed.
bin/rails runner 'Locatable.without_location_scope { NameSearchService.unindexed_person_names.find_each { |n| NameSearchService.index_person_name(n) } }'

# CouchDB patient documents. Start a Sidekiq worker first: sync:all only queues the jobs.
bundle exec sidekiq -C config/sidekiq.yml      # in another terminal; leave it running
bin/rails 'sync:all[rebuild_patients]'
```

Then search for a few AETC patients and compare their visits, encounters and lab orders with AETC.

## What was migrated, and what was not

Each run writes to a tracking schema named `<AETC schema>_migration`, for example `aetc_live_prod_migration`:

| Table | Contents |
|---|---|
| `id_map` | Every AETC row that was migrated (`entity`, `src_id`) and the MaHIS id it became (`tgt_id`) |
| `migration_log` | Every AETC row that was skipped, or loaded but changed or flagged, with a `reason` and `detail` |
| `checkpoint` | How far each step got |
| `settings` | The migration user's id; when `aetc:check` last passed |
| `users_lookup` | Each AETC user and the MaHIS user it became |
| `lookup_*` | The mapping files, loaded as tables |

To see which reasons were logged and how often:

```sql
SELECT step, entity, reason, COUNT(*) FROM aetc_live_prod_migration.migration_log
GROUP BY step, entity, reason ORDER BY step, COUNT(*) DESC;
```

### Main rules

- **Users:** every AETC user becomes a MaHIS user (decided 2026-10-13).
  - A username MaHIS already has gets `_aetc` appended (`admin` → `admin_aetc`, then `_aetc2`, …). Each run lists the renamed users in `log/aetc_migration/<tracking>-usernames-taken-<timestamp>.csv` and logs them as `username_taken`.
  - The accounts have no password: an admin sets one before the first login. Users retired in AETC stay retired.
  - Facility QECH (1291) and access to the AETC program (30), from `users.json`.
  - AETC roles that exist in MaHIS are copied; the others are logged (`role_not_in_mahis`).
  - The user's AETC person is migrated and linked to the account, including persons who are only users.
  - The creator, changer, voider and orderer of every migrated row is the AETC user's MaHIS account. An encounter's provider is the person of the user who created it, because AETC recorded no encounter providers.
  - The `aetc_migration` user (no password) owns the new accounts and stands in for AETC user ids that no longer exist.
- **Voided rows:** voided rows of active patients are not migrated. A voided patient comes over with its voided rows, still voided.
- **Same uuid:** AETC rows whose uuid MaHIS already has are skipped (`uuid_exists_in_target`).
- **Identifiers:** Dummy IDs are skipped (`identifier_type_skipped`). An identifier used by two AETC patients, or already used in MaHIS, is loaded and flagged (`duplicate_identifier`, `identifier_exists_in_target`).
- **Locations:** encounters and obs at AETC location 1 ("Unknown") are recorded at QECH (1291). For encounters this is logged as `location_overridden`.
- **Obs values:**
  - Coded answers are translated through `concept.json`. An answer with no MaHIS concept is kept as text (`answer_unmapped`).
  - Text answers of `text_to_coded` concepts become coded only when the concept is reviewed. Otherwise they stay as text (`conversion_not_reviewed`, `value_unmapped`).
  - Lab tests whose results AETC stored partly as numbers and partly as text (the full blood count tests, urea, GGT, AST, ALT) go entirely into `value_text`: numbers are written as text (`250` → `'250'`), and text such as `NaN` or `^1.9` is kept as it is. This is the `numeric_to_text` rule in `concept.json`, decided on 2026-10-12.
  - Obs whose concept has no MaHIS concept are skipped (`concept_unmapped`).
- **Lab orders:**
  - An empty start date becomes the date created (`start_date_filled`).
  - Fractions of seconds are dropped.
  - An accession number MaHIS already uses is flagged (`accession_exists_in_target`).
  - A LIMS id MaHIS already has is skipped (`lims_id_exists_in_target`).
- **Missing parent:** a row whose parent was not migrated (encounter, visit, order, obs group) is skipped or loaded without the link. The reason names what was missing.

## Mapping files (`mappings/`)

| File | Maps |
|---|---|
| `concept.json` | Obs concepts, coded answers, value conversions (`text_to_coded` value maps, review flags), specimens |
| `concept_unmapped_values.csv` | AETC text values that could not be converted; fill in the last column to extend the value maps |
| `encounter_type.json` | Encounter types, and the AETC program |
| `location.json` | Locations, including `clinical_overrides` (1 → 1291 for encounters and obs) |
| `order_type.json` | Order types, and the specimen concepts of lab orders |
| `patient_identifier_type.json` | Identifier types (including which are skipped) |
| `person_address.json` | Address columns: which AETC column goes where, values treated as empty, which address is kept |
| `person_attribute_type.json` | Person attribute types |
| `relationship_type.json` | Relationship types |
| `users.json` | How AETC users are migrated (`per_user`), their facility and program, and AETC user reference counts |
| `value_normalization.json` | Gender and country values, and text treated as empty (`N/A`, …) |
| `visit_type.json` | Visit types |
| `decisions.json` | The decisions behind the mappings, for reference |

`aetc:migrate` reloads the mapping files every time it starts. Edits only affect rows that have not been migrated yet. To apply a mapping change to rows already migrated, restore the MaHIS backup and run again.

Rows that were *skipped* (for example `concept_unmapped`) can be brought in after you map them, without restoring:

1. Delete their `migration_log` rows.
2. Set the step's `checkpoint` back to 0.
3. Run that step again, for example `bin/rails "aetc:migrate[obs]"`.

The step only inserts rows that are not in `id_map` yet. A fresh run gives the same result.

## Cleaning up

```bash
bin/rails aetc:schemas            # schemas this tool created (AETC copies and tracking schemas)
bin/rails aetc:cleanup            # drop them, one at a time, after you type each schema's name
bin/rails "aetc:cleanup[aetc_live_prod_migration]"
```

- **What can be dropped:** only schemas the tool created (they carry an `_aetc_migration` marker table). The MaHIS database is never offered.
- **CSV copy first:** before a tracking schema is dropped, its `id_map` and `migration_log` are exported to `log/aetc_migration/<schema>-<timestamp>/`.
- **Keep the tracking schema** until every skipped or flagged row has been reviewed.

## Troubleshooting

| Message | Fix |
|---|---|
| `No AETC schema is loaded yet` | Run `aetc:load`, or set `AETC_SOURCE_DB` to the schema where AETC is restored |
| `Invalid schema name "aetc_live_prod,"` | Remove the comma: `AETC_SOURCE_DB=aetc_live_prod bin/rails …` |
| `rake aetc:check has not passed` | Run `bin/rails aetc:check` and fix what it reports |
| `… already contains AETC encounters` | The target database already has AETC data. Restore the backup taken before the earlier migration. |
| A run stopped (error, Ctrl-C, closed laptop) | Run the same command again. Finished batches are kept; the batch that was running was rolled back. |
| Patients don't show in MaHIS | Index the names, start Sidekiq, and rebuild CouchDB (see "After the run") |
| Log file | Every command writes `log/aetc-migration-<timestamp>.log` |

## Tests

```bash
bundle exec rspec spec/services/aetc_migration_spec.rb
```

**How the spec works:**

- It builds throwaway schemas on the test MySQL server: `aetc_test_src`, `aetc_test_tgt`, and `aetc_test_src_migration`.
- `aetc_test_src` is a small AETC database: `spec/fixtures/aetc_migration/aetc_schema.sql`, plus rows seeded by `spec/support/helpers/aetc_migration_fixture.rb`.
- `aetc_test_tgt` holds empty copies of the MaHIS tables, taken from the test database, which is only read.
- It runs all eight steps and checks each rule above, as well as dry runs, `LIMIT`, re-runs and `aetc:cleanup`.
- The MySQL user needs permission to create and drop databases.

**Parity with the Python scripts:** these tasks replace the Python scripts used for the first AETC migration (`migration/01–09_*.py`). In October 2026 both were run on the same seeded data, and the results were identical for every table, `id_map` and `migration_log`. There were two intended differences:

- Encounters at AETC location 1 now go to 1291; the Python scripts left them without a location.
- The obs `order_not_migrated` log entry now comes from the `obs` step.
