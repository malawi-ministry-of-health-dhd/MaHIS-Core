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

## OFFLINE 

# sync all records with couchDB

- rails sync:all

# Run only one job (e.g. StageSyncJob)

- rails "sync:run[StageSyncJob]"

# Start all listeners

- rails couchdb:start_all_listeners