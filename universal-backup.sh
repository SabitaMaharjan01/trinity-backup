#!/usr/bin/env bash
# Universal configurable Linux backup script.
# Keep this script identical on every server; change only the adjacent .env file.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  printf 'ERROR: Configuration file not found: %s\n' "$ENV_FILE" >&2
  exit 1
fi

# .env must be a trusted file owned/edited by the administrator.
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${BACKUP_DIR:=./backups}"
: "${BACKUP_DIRS:=false}"
: "${BACKUP_FILES:=false}"
: "${BACKUP_MYSQL:=false}"
: "${BACKUP_POSTGRES:=false}"
: "${BACKUP_MONGO:=false}"
: "${BACKUP_SQLITE:=false}"
: "${BACKUP_DIRECTORIES:=}"
: "${BACKUP_FILES_LIST:=}"
: "${MYSQL_DATABASES:=ALL}"
: "${MYSQL_USER:=}"
: "${MYSQL_PASSWORD:=}"
: "${MYSQL_HOST:=localhost}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_DEFAULTS_FILE:=}"
: "${POSTGRES_DATABASES:=ALL}"
: "${POSTGRES_USER:=}"
: "${POSTGRES_PASSWORD:=}"
: "${POSTGRES_HOST:=}"
: "${POSTGRES_PORT:=5432}"
: "${MONGO_URI:=}"
: "${MONGO_DATABASES:=ALL}"
: "${SQLITE_DATABASES:=}"
: "${RCLONE_UPLOAD:=false}"
: "${RCLONE_REMOTE:=gdrive}"
: "${GDRIVE_DESTINATION:=backups}"
: "${RETENTION_DAYS:=30}"
: "${BACKUP_PREFIX:=backup}"

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: RETENTION_DAYS must be a non-negative integer.\n' >&2
  exit 1
fi

mkdir -p -- "$BACKUP_DIR"
BACKUP_DIR="$(cd -- "$BACKUP_DIR" && pwd)"
LOG_FILE="${LOG_FILE:-${BACKUP_DIR}/backup.log}"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

HOST="$(hostname -s 2>/dev/null || hostname)"
HOST="${HOST//[^a-zA-Z0-9._-]/_}"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
ARCHIVE_NAME="${HOST}_${BACKUP_PREFIX}-${TIMESTAMP}.tar.gz"
FINAL_ARCHIVE="${BACKUP_DIR}/${ARCHIVE_NAME}"
TEMP_ARCHIVE="${BACKUP_DIR}/.${ARCHIVE_NAME}.tmp"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/universal-backup.XXXXXX")"
STAGE_DIR="${WORK_DIR}/payload"
mkdir -p "$STAGE_DIR/filesystem" "$STAGE_DIR/database_dumps"
SUCCESS=0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  rm -rf -- "$WORK_DIR"
  if [[ -f "$TEMP_ARCHIVE" ]]; then
    rm -f -- "$TEMP_ARCHIVE"
  fi
}
trap cleanup EXIT

is_enabled() {
  case "${1,,}" in
    true|yes|1|on) return 0 ;;
    false|no|0|off|'') return 1 ;;
    *) die "Invalid boolean value '$1'. Use true or false." ;;
  esac
}

# Read a pipe-separated list into the named array. Paths may contain spaces,
# but must not contain the pipe character.
split_list() {
  local value="${1:-}"
  local -n output_array="$2"
  output_array=()
  [[ -n "$value" ]] || return 0
  IFS='|' read -r -a output_array <<< "$value"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

copy_path_into_payload() {
  local path="$1"
  [[ -e "$path" ]] || die "Configured path does not exist: $path"
  cp -a --parents -- "$path" "${STAGE_DIR}/filesystem/"
  log "Added filesystem path: $path"
}

log "Backup started: ${ARCHIVE_NAME}"
log "Configuration: ${ENV_FILE}"

# 1. Directory backups
if is_enabled "$BACKUP_DIRS"; then
  split_list "$BACKUP_DIRECTORIES" directories
  for path in "${directories[@]}"; do
    [[ -n "$path" ]] || continue
    [[ -d "$path" ]] || die "Configured directory is not a directory: $path"
    copy_path_into_payload "$path"
  done
fi

# 2. Individual file/path backups
if is_enabled "$BACKUP_FILES"; then
  split_list "$BACKUP_FILES_LIST" files
  for path in "${files[@]}"; do
    [[ -n "$path" ]] || continue
    copy_path_into_payload "$path"
  done
fi

# 3. MySQL / MariaDB
if is_enabled "$BACKUP_MYSQL"; then
  if command -v mysqldump >/dev/null 2>&1; then
    MYSQL_DUMP="$(command -v mysqldump)"
  elif command -v mariadb-dump >/dev/null 2>&1; then
    MYSQL_DUMP="$(command -v mariadb-dump)"
  else
    die "BACKUP_MYSQL=true but neither mysqldump nor mariadb-dump is installed."
  fi

  split_list "$MYSQL_DATABASES" mysql_dbs
  ((${#mysql_dbs[@]} > 0)) || die "BACKUP_MYSQL=true but MYSQL_DATABASES is empty."
  mysql_args=()
  if [[ -n "$MYSQL_DEFAULTS_FILE" ]]; then
    [[ -r "$MYSQL_DEFAULTS_FILE" ]] || die "Cannot read MYSQL_DEFAULTS_FILE: $MYSQL_DEFAULTS_FILE"
    mysql_args+=( "--defaults-extra-file=${MYSQL_DEFAULTS_FILE}" )
  else
    [[ -n "$MYSQL_USER" ]] || die "Set MYSQL_USER or MYSQL_DEFAULTS_FILE for MySQL backups."
    mysql_args+=( "--user=${MYSQL_USER}" "--host=${MYSQL_HOST}" "--port=${MYSQL_PORT}" )
  fi

  mysql_env=()
  [[ -n "$MYSQL_PASSWORD" && -z "$MYSQL_DEFAULTS_FILE" ]] && mysql_env+=( "MYSQL_PWD=${MYSQL_PASSWORD}" )
  if [[ "${mysql_dbs[0]}" == "ALL" ]]; then
    log "Dumping all MySQL/MariaDB databases."
    env "${mysql_env[@]}" "$MYSQL_DUMP" "${mysql_args[@]}" \
      --all-databases --single-transaction --routines --events --triggers \
      > "${STAGE_DIR}/database_dumps/mysql-all.sql" \
      || die "MySQL/MariaDB dump failed."
  else
    log "Dumping selected MySQL/MariaDB databases."
    env "${mysql_env[@]}" "$MYSQL_DUMP" "${mysql_args[@]}" \
      --databases "${mysql_dbs[@]}" --single-transaction --routines --events --triggers \
      > "${STAGE_DIR}/database_dumps/mysql-selected.sql" \
      || die "MySQL/MariaDB dump failed."
  fi
fi

# 4. PostgreSQL
if is_enabled "$BACKUP_POSTGRES"; then
  require_command pg_dump
  require_command pg_dumpall
  split_list "$POSTGRES_DATABASES" postgres_dbs
  ((${#postgres_dbs[@]} > 0)) || die "BACKUP_POSTGRES=true but POSTGRES_DATABASES is empty."

  pg_env=( "PGPORT=${POSTGRES_PORT}" )
  [[ -n "$POSTGRES_USER" ]] && pg_env+=( "PGUSER=${POSTGRES_USER}" )
  [[ -n "$POSTGRES_HOST" ]] && pg_env+=( "PGHOST=${POSTGRES_HOST}" )
  [[ -n "$POSTGRES_PASSWORD" ]] && pg_env+=( "PGPASSWORD=${POSTGRES_PASSWORD}" )

  if [[ "${postgres_dbs[0]}" == "ALL" ]]; then
    log "Dumping all PostgreSQL databases and global objects."
    env "${pg_env[@]}" pg_dumpall \
      > "${STAGE_DIR}/database_dumps/postgres-all.sql" \
      || die "PostgreSQL pg_dumpall failed."
  else
    for db in "${postgres_dbs[@]}"; do
      [[ -n "$db" ]] || continue
      safe_db="${db//[^a-zA-Z0-9._-]/_}"
      log "Dumping PostgreSQL database: $db"
      env "${pg_env[@]}" pg_dump --format=custom --no-owner --no-acl \
        --dbname="$db" --file="${STAGE_DIR}/database_dumps/postgres-${safe_db}.dump" \
        || die "PostgreSQL dump failed for database: $db"
    done
  fi
fi

# 5. MongoDB. ALL creates one archive of all databases accessible to the URI.
if is_enabled "$BACKUP_MONGO"; then
  require_command mongodump
  [[ -n "$MONGO_URI" ]] || die "Set MONGO_URI when BACKUP_MONGO=true."
  split_list "$MONGO_DATABASES" mongo_dbs
  ((${#mongo_dbs[@]} > 0)) || die "BACKUP_MONGO=true but MONGO_DATABASES is empty."

  if [[ "${mongo_dbs[0]}" == "ALL" ]]; then
    log "Dumping all MongoDB databases accessible to the configured URI."
    mongodump --uri="$MONGO_URI" --archive="${STAGE_DIR}/database_dumps/mongodb-all.archive.gz" --gzip \
      || die "MongoDB dump failed."
  else
    for db in "${mongo_dbs[@]}"; do
      [[ -n "$db" ]] || continue
      safe_db="${db//[^a-zA-Z0-9._-]/_}"
      log "Dumping MongoDB database: $db"
      mongodump --uri="$MONGO_URI" --db="$db" \
        --archive="${STAGE_DIR}/database_dumps/mongodb-${safe_db}.archive.gz" --gzip \
        || die "MongoDB dump failed for database: $db"
    done
  fi
fi

# 6. SQLite. Each configured item is a path to a SQLite database file.
if is_enabled "$BACKUP_SQLITE"; then
  require_command sqlite3
  split_list "$SQLITE_DATABASES" sqlite_dbs
  ((${#sqlite_dbs[@]} > 0)) || die "BACKUP_SQLITE=true but SQLITE_DATABASES is empty."
  index=0
  for db in "${sqlite_dbs[@]}"; do
    [[ -n "$db" ]] || continue
    [[ -f "$db" ]] || die "SQLite database file not found: $db"
    index=$((index + 1))
    safe_db="$(basename -- "$db" | sed 's/[^a-zA-Z0-9._-]/_/g')"
    destination="${STAGE_DIR}/database_dumps/sqlite-${index}-${safe_db}"
    log "Backing up SQLite database: $db"
    # sqlite3 .backup provides a consistent online backup for a live database.
    sqlite3 "$db" ".backup '${destination}'" \
      || die "SQLite backup failed for: $db"
  done
fi

# Write a small manifest into the archive.
{
  printf 'hostname=%s\n' "$HOST"
  printf 'created_at=%s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
  printf 'archive=%s\n' "$ARCHIVE_NAME"
  printf 'backup_script=universal-backup.sh\n'
} > "${STAGE_DIR}/BACKUP-MANIFEST.txt"

# Create the archive only after all selected backup jobs have succeeded.
require_command tar
require_command gzip
log "Creating compressed archive."
tar -czf "$TEMP_ARCHIVE" -C "$STAGE_DIR" . || die "Archive creation failed."
[[ -s "$TEMP_ARCHIVE" ]] || die "Archive was not created or is empty."
mv -- "$TEMP_ARCHIVE" "$FINAL_ARCHIVE"
chmod 600 "$FINAL_ARCHIVE"
log "Local archive created: $FINAL_ARCHIVE"

# 7. Optional rclone upload. A failed upload leaves the local archive intact
# and exits with an error so monitoring/cron can detect the failure.
if is_enabled "$RCLONE_UPLOAD"; then
  require_command rclone
  [[ -n "$RCLONE_REMOTE" ]] || die "RCLONE_REMOTE cannot be empty when upload is enabled."
  [[ -n "$GDRIVE_DESTINATION" ]] || die "GDRIVE_DESTINATION cannot be empty when upload is enabled."
  REMOTE_PATH="${RCLONE_REMOTE}:${GDRIVE_DESTINATION%/}"
  log "Uploading archive to ${REMOTE_PATH}/"
  rclone copyto "$FINAL_ARCHIVE" "${REMOTE_PATH}/${ARCHIVE_NAME}" \
    || die "rclone upload failed. Local archive retained at: $FINAL_ARCHIVE"
  log "Upload completed."
fi

# 8. Local retention cleanup for archives created by this script.
if (( RETENTION_DAYS > 0 )); then
  find "$BACKUP_DIR" -maxdepth 1 -type f \
    -name "${HOST}_${BACKUP_PREFIX}-*.tar.gz" \
    -mtime "+${RETENTION_DAYS}" -print -delete >> "$LOG_FILE" 2>&1 \
    || die "Local retention cleanup failed."
  log "Local retention cleanup completed (older than ${RETENTION_DAYS} days)."
else
  log "Local retention cleanup disabled (RETENTION_DAYS=0)."
fi

log "Backup completed successfully: $FINAL_ARCHIVE"
exit 0
