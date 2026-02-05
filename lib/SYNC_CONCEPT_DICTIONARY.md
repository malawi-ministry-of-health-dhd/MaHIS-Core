# Concept Dictionary Sync Script

This script synchronizes the `config/ConceptNameDictionary.json` file with the current concept names from the OpenMRS database.

## Purpose

Over time, concept names in the database may be updated or corrected. This script ensures that your `ConceptNameDictionary.json` file reflects the current concept names stored in the database, using the `concept_id` as the matching key.

## Features

- ✅ Fetches the latest concept names from the database
- ✅ Preserves the JSON structure and categories
- ✅ Creates an automatic timestamped backup before making changes
- ✅ Provides detailed output showing all changes
- ✅ Handles missing concepts gracefully
- ✅ Prioritizes English locale and fully specified names

## Usage

You can run the script in two ways:

### Option 1: Using Rake Task (Recommended)

```bash
bundle exec rake concepts:sync_dictionary
```

### Option 2: Using Rails Runner

```bash
bundle exec rails runner lib/sync_concept_dictionary.rb
```

## What It Does

1. **Reads** the current `config/ConceptNameDictionary.json` file
2. **Creates** a timestamped backup (e.g., `ConceptNameDictionary.json.backup.20260205_143022`)
3. **Queries** the database for each `concept_id` in the dictionary
4. **Updates** concept names that have changed
5. **Reports** summary statistics:
   - Number of concepts updated
   - Number unchanged
   - Number missing from database

## Database Query Logic

The script queries the `concept_name` table and prioritizes:
1. English locale names (`en` or `en_*`)
2. Fully specified names over short names
3. Non-voided records only

## Example Output

```
Starting concept dictionary sync...
Reading dictionary from: /path/to/config/ConceptNameDictionary.json
Found 2719 entries in dictionary
Backup created at: /path/to/config/ConceptNameDictionary.json.backup.20260205_143022

Updating concept names from database...
  [11887] Updating: 'Reason for BDE' -> 'Reason for baseline evaluation'
  [2676] Unchanged: 'Prescription refill date'
  [10550] Updating: 'Benign warts' -> 'Benign genital warts'
  ...

Dictionary updated successfully at: /path/to/config/ConceptNameDictionary.json

============================================================
SYNC SUMMARY
============================================================
Updated:   45 concepts
Unchanged: 2670 concepts
Missing:   4 concepts (not found in database)
============================================================
```

## Safety Features

- **Automatic Backup**: Every run creates a timestamped backup file before making changes
- **Warning Messages**: Alerts you to concepts that exist in the JSON but not in the database
- **Preserves Structure**: Maintains all other JSON fields (like `categories`)
- **Error Handling**: Graceful error handling with clear error messages

## Rollback

If you need to revert to the previous version:

```bash
# Find your backup file
ls -lt config/ConceptNameDictionary.json.backup.*

# Restore it
cp config/ConceptNameDictionary.json.backup.YYYYMMDD_HHMMSS config/ConceptNameDictionary.json
```

## Requirements

- Rails environment must be properly configured
- Database connection must be active
- `concept_name` table must be accessible

## Troubleshooting

### "Dictionary file not found"
- Ensure you're running the script from the Rails root directory
- Check that `config/ConceptNameDictionary.json` exists

### "Failed to parse JSON file"
- Verify the JSON file is valid
- Check for syntax errors in the file

### Database connection errors
- Verify your `config/database.yml` is configured correctly
- Ensure the database server is running and accessible

## Files

- **Script**: `lib/sync_concept_dictionary.rb`
- **Rake Task**: `lib/tasks/sync_concept_dictionary.rake`
- **Dictionary**: `config/ConceptNameDictionary.json`
- **Backups**: `config/ConceptNameDictionary.json.backup.*`
