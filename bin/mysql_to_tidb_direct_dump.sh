#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Create a consistent MySQL dump and import it into an empty TiDB database.

Required environment variables:
  SOURCE_DB_HOST, SOURCE_DB_USERNAME, SOURCE_DB_PASSWORD
  TARGET_DB_HOST, TARGET_DB_USERNAME, TARGET_DB_PASSWORD

Optional environment variables:
  ENV_FILE=.env.tidb-migration
  MYSQL_CLIENT=/path/to/mysql       MYSQLDUMP_CLIENT=/path/to/mysqldump
  SOURCE_DB_PORT=3306               TARGET_DB_PORT=4000
  SOURCE_DB_NAME=mahis_moses        TARGET_DB_NAME=$SOURCE_DB_NAME
  SOURCE_SSL_MODE=DISABLED          TARGET_SSL_MODE=DISABLED
  SOURCE_SSL_CA=                    TARGET_SSL_CA=
  TARGET_ADMIN_USERNAME=            TARGET_ADMIN_PASSWORD=
  TARGET_DB_USER_HOST=%
  LOCAL_TIFLASH_CONTAINER=          TIDB_READY_TIMEOUT=120
  EXCLUDED_TABLE_DATA=immunization_cache_data
  STRIP_DEFINERS=true
  DROP_TARGET_ON_FAILURE=false
  DUMP_DIR=tmp/tidb_migrations      VERIFY_ROW_COUNTS=true
  CONFIRM_SOURCE_WRITES_STOPPED=false

Example:
  ENV_FILE=.env.tidb-migration bin/mysql_to_tidb_direct_dump.sh

Or provide variables directly:
  CONFIRM_SOURCE_WRITES_STOPPED=true \
  SOURCE_DB_HOST=mysql.example SOURCE_DB_USERNAME=dm SOURCE_DB_PASSWORD='...' \
  TARGET_DB_HOST=tidb.example TARGET_DB_USERNAME=root TARGET_DB_PASSWORD='...' \
  bin/mysql_to_tidb_direct_dump.sh

The target database must be empty. Stored routines, triggers, and events are
intentionally excluded because TiDB does not support the MAHIS routine set.
USAGE
}

[[ "${1:-}" != "--help" && "${1:-}" != "-h" ]] || { usage; exit 0; }

if [[ -n "${ENV_FILE:-}" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    printf 'Environment file does not exist: %s\n' "$ENV_FILE" >&2
    exit 2
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

required_variables=(
  SOURCE_DB_HOST SOURCE_DB_USERNAME SOURCE_DB_PASSWORD
  TARGET_DB_HOST TARGET_DB_USERNAME TARGET_DB_PASSWORD
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    printf 'Missing required environment variable: %s\n\n' "$variable" >&2
    usage >&2
    exit 2
  fi
done

SOURCE_DB_PORT="${SOURCE_DB_PORT:-3306}"
SOURCE_DB_NAME="${SOURCE_DB_NAME:-mahis_moses}"
TARGET_DB_PORT="${TARGET_DB_PORT:-4000}"
TARGET_DB_NAME="${TARGET_DB_NAME:-$SOURCE_DB_NAME}"
SOURCE_SSL_MODE="${SOURCE_SSL_MODE:-DISABLED}"
TARGET_SSL_MODE="${TARGET_SSL_MODE:-DISABLED}"
VERIFY_ROW_COUNTS="${VERIFY_ROW_COUNTS:-true}"
DUMP_DIR="${DUMP_DIR:-tmp/tidb_migrations}"
TIDB_READY_TIMEOUT="${TIDB_READY_TIMEOUT:-120}"
EXCLUDED_TABLE_DATA="${EXCLUDED_TABLE_DATA:-immunization_cache_data}"
STRIP_DEFINERS="${STRIP_DEFINERS:-true}"

if [[ ! "$SOURCE_DB_PORT" =~ ^[1-9][0-9]*$ || ! "$TARGET_DB_PORT" =~ ^[1-9][0-9]*$ || ! "$TIDB_READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Database ports and TIDB_READY_TIMEOUT must be positive integers.\n' >&2
  exit 2
fi

for database in "$SOURCE_DB_NAME" "$TARGET_DB_NAME"; do
  if [[ ! "$database" =~ ^[A-Za-z0-9_$]+$ ]]; then
    printf 'Unsafe database name: %s\n' "$database" >&2
    exit 2
  fi
done

excluded_tables=()
if [[ -n "$EXCLUDED_TABLE_DATA" ]]; then
  IFS=',' read -r -a excluded_tables <<< "$EXCLUDED_TABLE_DATA"
  for index in "${!excluded_tables[@]}"; do
    table="${excluded_tables[$index]//[[:space:]]/}"
    if [[ ! "$table" =~ ^[A-Za-z0-9_$]+$ ]]; then
      printf 'Unsafe excluded table name: %s\n' "$table" >&2
      exit 2
    fi
    excluded_tables[$index]="$table"
  done
fi

TARGET_DB_USER_HOST="${TARGET_DB_USER_HOST:-%}"
if [[ ! "$TARGET_DB_USERNAME" =~ ^[A-Za-z0-9_.@+-]+$ || ! "$TARGET_DB_USER_HOST" =~ ^[A-Za-z0-9_.:%+-]+$ ]]; then
  printf 'Unsafe target database username or account host.\n' >&2
  exit 2
fi

if [[ "${CONFIRM_SOURCE_WRITES_STOPPED:-false}" != "true" ]]; then
  cat >&2 <<'ERROR'
Refusing to migrate while source writes might still be active.
Stop Puma, Sidekiq, schedulers, offline/CouchDB listeners, and integrations,
then rerun with CONFIRM_SOURCE_WRITES_STOPPED=true.
ERROR
  exit 2
fi

mysql_client_prefix=''
if command -v brew >/dev/null 2>&1; then
  mysql_client_prefix="$(brew --prefix mysql-client@8.4 2>/dev/null || true)"
fi

client_directories=()
[[ -z "$mysql_client_prefix" ]] || client_directories+=("$mysql_client_prefix/bin")
client_directories+=(
  /opt/homebrew/opt/mysql-client@8.4/bin
  /usr/local/opt/mysql-client@8.4/bin
)

for client_directory in "${client_directories[@]}"; do
  if [[ -z "${MYSQL_CLIENT:-}" && -x "$client_directory/mysql" ]]; then
    MYSQL_CLIENT="$client_directory/mysql"
  fi
  if [[ -z "${MYSQLDUMP_CLIENT:-}" && -x "$client_directory/mysqldump" ]]; then
    MYSQLDUMP_CLIENT="$client_directory/mysqldump"
  fi
done

MYSQL_CLIENT="${MYSQL_CLIENT:-$(command -v mysql || true)}"
MYSQLDUMP_CLIENT="${MYSQLDUMP_CLIENT:-$(command -v mysqldump || true)}"

for client in "$MYSQL_CLIENT" "$MYSQLDUMP_CLIENT"; do
  if [[ -z "$client" || ! -x "$client" ]]; then
    printf 'Required MySQL client is missing or not executable: %s\n' "$client" >&2
    exit 127
  fi
done
command -v gzip >/dev/null 2>&1 || { printf 'Required command not found: gzip\n' >&2; exit 127; }

printf 'Using mysql client: %s\n' "$MYSQL_CLIENT"
printf 'Using dump client:  %s\n' "$MYSQLDUMP_CLIENT"

mkdir -p "$DUMP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
dump_file="$DUMP_DIR/${SOURCE_DB_NAME}_${timestamp}.sql.gz"
partial_dump="${dump_file}.partial"
source_config="$(mktemp "${TMPDIR:-/tmp}/mahis-mysql-source.XXXXXX")"
target_config="$(mktemp "${TMPDIR:-/tmp}/mahis-tidb-target.XXXXXX")"
admin_config=''
table_file="$(mktemp "${TMPDIR:-/tmp}/mahis-tables.XXXXXX")"
restart_tiflash_on_exit=false

cleanup() {
  exit_status=$?
  trap - EXIT

  if [[ "$exit_status" != "0" && "${DROP_TARGET_ON_FAILURE:-false}" == "true" ]]; then
    printf 'Dropping partial target database %s after failure...\n' "$TARGET_DB_NAME"
    if [[ -n "$admin_config" ]]; then
      "$MYSQL_CLIENT" --defaults-extra-file="$admin_config" -e "DROP DATABASE IF EXISTS \`${TARGET_DB_NAME}\`" >/dev/null 2>&1 || true
    else
      "$MYSQL_CLIENT" --defaults-extra-file="$target_config" -e "DROP DATABASE IF EXISTS \`${TARGET_DB_NAME}\`" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$source_config" "$target_config" "$table_file" "$partial_dump"
  [[ -z "$admin_config" ]] || rm -f "$admin_config"
  if [[ "$restart_tiflash_on_exit" == "true" ]]; then
    printf 'Restarting local TiFlash container %s...\n' "$LOCAL_TIFLASH_CONTAINER"
    docker start "$LOCAL_TIFLASH_CONTAINER" >/dev/null || true
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'printf "Migration failed at line %s. The source database was not modified.\n" "$LINENO" >&2' ERR

write_client_config() {
  local path="$1" host="$2" port="$3" user="$4" password="$5" ssl_mode="$6" ssl_ca="$7"
  local value

  for value in "$host" "$port" "$user" "$password" "$ssl_mode" "$ssl_ca"; do
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
      printf 'Database connection values must not contain newlines.\n' >&2
      exit 2
    fi
  done

  host="${host//\\/\\\\}"; host="${host//\"/\\\"}"
  port="${port//\\/\\\\}"; port="${port//\"/\\\"}"
  user="${user//\\/\\\\}"; user="${user//\"/\\\"}"
  password="${password//\\/\\\\}"; password="${password//\"/\\\"}"
  ssl_mode="${ssl_mode//\\/\\\\}"; ssl_mode="${ssl_mode//\"/\\\"}"
  ssl_ca="${ssl_ca//\\/\\\\}"; ssl_ca="${ssl_ca//\"/\\\"}"
  {
    printf '[client]\n'
    printf 'host="%s"\nport="%s"\nuser="%s"\npassword="%s"\n' "$host" "$port" "$user" "$password"
    printf 'default-character-set=utf8mb4\nssl-mode="%s"\n' "$ssl_mode"
    [[ -z "$ssl_ca" ]] || printf 'ssl-ca="%s"\n' "$ssl_ca"
  } > "$path"
  chmod 600 "$path"
}

write_client_config "$source_config" "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" \
  "$SOURCE_DB_USERNAME" "$SOURCE_DB_PASSWORD" "$SOURCE_SSL_MODE" "${SOURCE_SSL_CA:-}"
write_client_config "$target_config" "$TARGET_DB_HOST" "$TARGET_DB_PORT" \
  "$TARGET_DB_USERNAME" "$TARGET_DB_PASSWORD" "$TARGET_SSL_MODE" "${TARGET_SSL_CA:-}"

if [[ -n "${TARGET_ADMIN_USERNAME:-}" ]]; then
  admin_config="$(mktemp "${TMPDIR:-/tmp}/mahis-tidb-admin.XXXXXX")"
  write_client_config "$admin_config" "$TARGET_DB_HOST" "$TARGET_DB_PORT" \
    "$TARGET_ADMIN_USERNAME" "${TARGET_ADMIN_PASSWORD:-}" "$TARGET_SSL_MODE" "${TARGET_SSL_CA:-}"
fi

source_mysql=("$MYSQL_CLIENT" --defaults-extra-file="$source_config" --batch --skip-column-names)
target_mysql=("$MYSQL_CLIENT" --defaults-extra-file="$target_config" --batch --skip-column-names)
admin_mysql=()
[[ -z "$admin_config" ]] || admin_mysql=("$MYSQL_CLIENT" --defaults-extra-file="$admin_config" --batch --skip-column-names)

printf 'Checking source MySQL database %s on %s:%s...\n' "$SOURCE_DB_NAME" "$SOURCE_DB_HOST" "$SOURCE_DB_PORT"
source_exists="$("${source_mysql[@]}" -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${SOURCE_DB_NAME}'")"
[[ "$source_exists" == "1" ]] || { printf 'Source database does not exist.\n' >&2; exit 1; }

source_data_tables=()
while IFS= read -r table; do
  excluded=false
  for excluded_table in "${excluded_tables[@]}"; do
    if [[ "$table" == "$excluded_table" ]]; then
      excluded=true
      break
    fi
  done
  [[ "$excluded" == "true" ]] || source_data_tables+=("$table")
done < <("${source_mysql[@]}" -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${SOURCE_DB_NAME}' AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME")

printf 'Checking target TiDB on %s:%s...\n' "$TARGET_DB_HOST" "$TARGET_DB_PORT"
target_version="$("${target_mysql[@]}" -e 'SELECT VERSION()')"
case "$target_version" in
  *TiDB*|*tidb*) ;;
  *)
    printf 'Target is not TiDB; server reported: %s\n' "$target_version" >&2
    exit 1
    ;;
esac

database_setup_sql="CREATE DATABASE IF NOT EXISTS \`${TARGET_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
if (( ${#admin_mysql[@]} )); then
  printf 'Creating target database and granting %s@%s with the TiDB admin account...\n' "$TARGET_DB_USERNAME" "$TARGET_DB_USER_HOST"
  "${admin_mysql[@]}" -e "${database_setup_sql}; GRANT ALL PRIVILEGES ON \`${TARGET_DB_NAME}\`.* TO '${TARGET_DB_USERNAME}'@'${TARGET_DB_USER_HOST}';"
elif ! "${target_mysql[@]}" -e "$database_setup_sql"; then
  cat >&2 <<'ERROR'
The target user cannot create the database. Either create and grant it manually,
or set TARGET_ADMIN_USERNAME and TARGET_ADMIN_PASSWORD for this preflight step.
ERROR
  exit 1
fi

target_tables="$("${target_mysql[@]}" -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${TARGET_DB_NAME}'")"
if [[ "$target_tables" != "0" ]]; then
  printf 'Target database %s is not empty (%s tables/views). Refusing to overwrite it.\n' "$TARGET_DB_NAME" "$target_tables" >&2
  exit 1
fi

if [[ -n "${LOCAL_TIFLASH_CONTAINER:-}" ]]; then
  command -v docker >/dev/null 2>&1 || {
    printf 'LOCAL_TIFLASH_CONTAINER is set, but docker is not installed.\n' >&2
    exit 127
  }
  tiflash_running="$(docker inspect --format '{{.State.Running}}' "$LOCAL_TIFLASH_CONTAINER" 2>/dev/null || true)"
  if [[ "$tiflash_running" == "true" ]]; then
    printf 'Pausing local TiFlash container %s to free memory during import...\n' "$LOCAL_TIFLASH_CONTAINER"
    docker stop "$LOCAL_TIFLASH_CONTAINER" >/dev/null
    restart_tiflash_on_exit=true
  elif [[ -z "$tiflash_running" ]]; then
    printf 'Configured TiFlash container does not exist: %s\n' "$LOCAL_TIFLASH_CONTAINER" >&2
    exit 1
  fi
fi

printf 'Waiting for TiDB schema writes to reach TiKV...\n'
ready_deadline=$(( $(date +%s) + TIDB_READY_TIMEOUT ))
while :; do
  if "${target_mysql[@]}" "$TARGET_DB_NAME" -e 'CREATE TABLE `__mahis_migration_readiness` (`id` BIGINT PRIMARY KEY); DROP TABLE `__mahis_migration_readiness`;' >/dev/null 2>&1; then
    break
  fi
  if (( $(date +%s) >= ready_deadline )); then
    printf 'TiDB did not complete a schema write within %s seconds. Check TiKV health.\n' "$TIDB_READY_TIMEOUT" >&2
    exit 1
  fi
  sleep 3
done

printf 'Dumping %s to %s...\n' "$SOURCE_DB_NAME" "$dump_file"
dump_options=(
  --defaults-extra-file="$source_config"
  --single-transaction --quick --hex-blob --no-tablespaces
  --skip-triggers --routines=false --events=false
  --default-character-set=utf8mb4 --set-gtid-purged=OFF
)
if "$MYSQLDUMP_CLIENT" --help 2>/dev/null | grep -q -- '--column-statistics'; then
  dump_options+=(--column-statistics=0)
fi
if (( ${#excluded_tables[@]} )); then
  printf 'Excluding rebuildable table data: %s\n' "${excluded_tables[*]}"
fi

emit_dump() {
  "$MYSQLDUMP_CLIENT" "${dump_options[@]}" --no-data "$SOURCE_DB_NAME"
  if (( ${#source_data_tables[@]} )); then
    "$MYSQLDUMP_CLIENT" "${dump_options[@]}" --no-create-info \
      "$SOURCE_DB_NAME" "${source_data_tables[@]}"
  fi
}

if [[ "$STRIP_DEFINERS" == "true" ]]; then
  printf 'Removing source-only DEFINER accounts from schema objects...\n'
  emit_dump | sed -E 's/DEFINER=`[^`]+`@`[^`]+`[[:space:]]+//' | gzip -c > "$partial_dump"
else
  emit_dump | gzip -c > "$partial_dump"
fi
gzip -t "$partial_dump"
mv "$partial_dump" "$dump_file"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$dump_file" > "${dump_file}.sha256"
else
  shasum -a 256 "$dump_file" > "${dump_file}.sha256"
fi

printf 'Importing dump into TiDB database %s...\n' "$TARGET_DB_NAME"
gzip -dc "$dump_file" | "${target_mysql[@]}" "$TARGET_DB_NAME"

source_table_count="$("${source_mysql[@]}" -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${SOURCE_DB_NAME}' AND TABLE_TYPE = 'BASE TABLE'")"
target_table_count="$("${target_mysql[@]}" -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${TARGET_DB_NAME}' AND TABLE_TYPE = 'BASE TABLE'")"
if [[ "$source_table_count" != "$target_table_count" ]]; then
  printf 'Table-count mismatch: source=%s target=%s\n' "$source_table_count" "$target_table_count" >&2
  exit 1
fi

if [[ "$VERIFY_ROW_COUNTS" == "true" ]]; then
  printf 'Comparing exact row counts for %s base tables...\n' "$source_table_count"
  "${source_mysql[@]}" -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${SOURCE_DB_NAME}' AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME" > "$table_file"
  while IFS= read -r table; do
    excluded=false
    for excluded_table in "${excluded_tables[@]}"; do
      if [[ "$table" == "$excluded_table" ]]; then
        excluded=true
        break
      fi
    done
    if [[ "$excluded" == "true" ]]; then
      printf '  %-45s %s\n' "$table" 'data intentionally excluded (rebuildable cache)'
      continue
    fi

    escaped_table="${table//\`/\`\`}"
    source_rows="$("${source_mysql[@]}" "$SOURCE_DB_NAME" -e "SELECT COUNT(*) FROM \`${escaped_table}\`")"
    target_rows="$("${target_mysql[@]}" "$TARGET_DB_NAME" -e "SELECT COUNT(*) FROM \`${escaped_table}\`")"
    if [[ "$source_rows" != "$target_rows" ]]; then
      printf 'Row-count mismatch for %s: source=%s target=%s\n' "$table" "$source_rows" "$target_rows" >&2
      exit 1
    fi
    printf '  %-45s %s\n' "$table" "$source_rows"
  done < "$table_file"
fi

printf '\nMigration completed successfully.\n'
printf 'Dump:     %s\n' "$dump_file"
printf 'Checksum: %s.sha256\n' "$dump_file"
printf 'Tables:   %s\n' "$target_table_count"
printf 'Next: configure MAHIS for TiDB, run db:migrate and db:tidb:check, then smoke-test before restoring writes.\n'
