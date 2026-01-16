# Concept Remapping Script

## Overview

This script handles the migration and remapping of medical concepts, drugs and other data between different database versions in the MaHIS-Core (Malawi Health Information System Core) application. It is designed to update references to concepts that have changed between database versions, ensuring data consistency across the system.

## Purpose

When upgrading or migrating the MaHIS-Core database, medical concepts (standardized medical terminologies) may change their IDs or names. This script:

1. Identifies concepts that have changed between the source and target databases
2. Finds or creates replacement concepts in the target database
3. Updates all references to the old concepts across multiple database tables
4. Maintains referential integrity throughout the migration process

## Files

- **main.rb**: The main script that performs the concept remapping
- **remap_tables.yml**: Configuration file listing all tables and columns that reference concepts
- **db/data/old_concepts.csv**: CSV file containing the old concept mappings (concept_id, name)

## Prerequisites

- Rails application must be initialized
- Database connections configured in `database.yml`:
  - `primary`: Target MaHIS-Core database
  - `source_db`: Source database with original concepts
    - ```yaml
            source_db:
                <<: *default
                database: kaporo
        ```
- User must exist in the database (script uses first user as creator)
- CSV file with old concepts must be present at `db/data/old_concepts.csv`

## How It Works

### 1. Initialization
```ruby
initialize_script
```
- Loads the `remap_tables.yml` configuration
- Sets the creator to the first user in the database

### 2. Database Connections

The script uses two separate database connections:

- **MasHISCoreDB**: Connects to the target MaHIS-Core database (primary)
- **SourceDB**: Connects to the source database being migrated from

### 3. Concept Processing

For each concept in `old_concepts.csv`:

1. **Check if concept has changed**: Compares concept ID and name between databases
2. **Find or create replacement**: 
   - Searches for existing concept by name in target database
   - Creates new concept if not found
3. **Update references**: Updates all foreign key references across configured tables

### 4. Tables Updated

The script updates concept references in the following tables (configurable via `remap_tables.yml`)

## Usage

### Running the Script

From the Rails application root:

```bash
rails runner bin/remap/main.rb
```

Or directly:

```bash
ruby bin/remap/main.rb
```

### CSV File Format

Create `db/data/old_concepts.csv` with the following format:

```csv
concept_id,name
123,Malaria
456,Tuberculosis
789,HIV Test
```

### Configuration

Edit `remap_tables.yml` to add or remove tables and columns:

```yaml
concepts:
  table_name:
    - column_name_1
    - column_name_2
```

## Transaction Safety

The script runs within a database transaction (`ActiveRecord::Base.transaction`). If any error occurs during processing:

- All changes are rolled back
- Database remains in its original state
- Error message is displayed

## Logging

The script provides verbose logging:

- All SQL queries are logged to stdout
- Progress messages for each concept update
- Clear section headers for readability

## Key Functions

### `concept_has_changed?(concept)`
Checks if a concept's ID or name has changed between databases.

### `concept_moved_to(concept)`
Finds the target concept by name, or creates a new one if it doesn't exist.

### `update_references(old_concept, new_concept, section)`
Updates all foreign key references from old concept ID to new concept ID across configured tables.

### `remap_concepts`
Main orchestration function that processes all concepts from the CSV file.

## Important Notes

⚠️ **Data Safety**
- Always backup your database before running this script
- Test on a development/staging environment first
- Review the `old_concepts.csv` file carefully

⚠️ **Database Requirements**
- Both source and target databases must be accessible
- Database user needs UPDATE privileges on all configured tables
- Sufficient transaction log space should be available

## Troubleshooting

### Error: "File not found: remap_tables.yml"
Ensure `bin/remap/remap_tables.yml` exists in the project.

### Error: "undefined method for nil:NilClass"
Check that at least one User exists in the database.

### Database connection errors
Verify `database.yml` has both `primary` and `source_db` configured.

## Extending the Script

To add support for remapping other types of data:
    - drugs
    - locations
    - e.t.c

1. Add a new section in `remap_tables.yml`
2. Create a corresponding `remap_<section>` method
3. Add the section symbol to the processing array:
   ```ruby
   %i[concepts <new_section>].each do |section|
     send("remap_#{section}")
   end
   ```