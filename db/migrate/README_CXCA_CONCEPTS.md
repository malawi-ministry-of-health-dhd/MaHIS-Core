# CxCa Workflow Missing Concepts

This directory contains tools to add missing concepts required for the Cervical Cancer (CxCa) workflow.

## Missing Concepts

The CxCa workflow was failing due to these missing concepts:

1. **"CxCa test"** - Used as an encounter type identifier in the workflow engine
2. **"Suspect cancer"** - Used for screening results and clinical findings
3. **"Cancer Suspect"** - Alternative name for the same concept

## Usage Options

### Option 1: Using Rails Migration (Recommended)

```bash
# Run the migration to add concepts
rails db:migrate

# To remove them later (rollback)
rails db:rollback
```

### Option 2: Using Rake Tasks

```bash
# Add the missing concepts
rails cxca:add_concepts

# Check status of concepts
rails cxca:status

# Remove the dummy concepts when you get real data
rails cxca:remove_concepts
```

## Concept Details

### CxCa test
- **Class**: Test (used for test/procedure concepts)
- **Datatype**: N/A (not associated with specific data)
- **Purpose**: Referenced in workflow engine as encounter type

### Suspect cancer
- **Class**: Finding (clinical observation/finding)  
- **Datatype**: N/A
- **Purpose**: Used in screening results for cancer suspicion
- **Alternative names**: "Cancer Suspect" (short name)

## Files Created

- `db/migrate/20260210000001_add_missing_cxca_concepts.rb` - Rails migration
- `lib/tasks/cxca_concepts.rake` - Rake tasks for easy management
- This README file for documentation

## Removal

When you receive the actual concept data/migrations from your team:

1. Use `rails cxca:remove_concepts` to clean up dummy data
2. Or run `rails db:rollback` to undo the migration
3. Then apply your official concept migrations

## Notes

- These are **dummy concepts** meant to be temporary
- The concepts use standard OpenMRS structure (concept + concept_name tables)
- UUIDs are auto-generated for proper OpenMRS compatibility
- Concepts are created with system user (ID: 1) as creator