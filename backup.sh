#!/usr/bin/env bash
#
# backup.sh: dump the databases and archive the folders and files listed in
# backup.conf.
#
# Usage:   sudo ./backup.sh daily|weekly|monthly|quarterly
#   daily      archives every path in DAILY_PATHS
#   weekly     archives every path in WEEKLY_PATHS
#   monthly    archives every path in MONTHLY_PATHS
#   quarterly  archives every path in QUARTERLY_PATHS
# Every run also dumps every database in DATABASES.
#
# The config is backup.conf next to this script. "The user" is whoever owns
# the folder this script is in (the user who cloned the repo), and backups go
# to that user's home:
#   /home/ttpl/trinity-backup/     <- this repo, with backup.conf
#   /home/ttpl/backups/
#     backup.log
#     daily/<YYYY-MM-DD>/<YYYY-MM-DD_HHMMSS>_<host>_<name>.tar.gz
#     weekly/<YYYY-MM-DD>/...
#     monthly/<YYYY-MM-DD>/...
#     quarterly/<YYYY-MM-DD>/...
#
# Each path (a folder or a single file) becomes one .tar.gz file named after
# its last part. Example:
#   /home/ttpl/docker/supabase-kalas
#   -> 2026-10-18_014000_ttpl-vps-eu_supabase-kalas.tar.gz
#
# Each database becomes one dump named after its Docker container. Example:
#   postgres supabase-db  -> 2026-10-18_014000_ttpl-vps-eu_supabase-db.sql.gz
#   mongo my-mongo        -> 2026-10-18_014000_ttpl-vps-eu_my-mongo.archive.gz
#
# Restore: sudo tar -xzf <file>.tar.gz -C <folder that contained the path>
# Database restores are in the README.
#
# Old run folders are deleted only after a run where everything worked.

set -euo pipefail
umask 077    # backups contain secrets: files 600, folders 700


# ----------------------------------------------------------------- logging

log()   { echo "$(date '+%F %T') [INFO]  $*"; }
warn()  { echo "$(date '+%F %T') [WARN]  $*" >&2; }
error() { echo "$(date '+%F %T') [ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }


# ----------------------------------------------------------------- setup

# Read backup.conf. Values set there replace the defaults below.
# The config can use $USER_HOME, for example "$USER_HOME/docker".
load_config() {
  BACKUP_DIR="$USER_HOME/backups"
  DAILY_PATHS=()
  WEEKLY_PATHS=()
  MONTHLY_PATHS=()
  QUARTERLY_PATHS=()
  DATABASES=()
  EXCLUDE_PATHS=()
  EXCLUDE_PATTERNS=()
  KEEP_DAILY_DAYS=7
  KEEP_WEEKLY_DAYS=28
  KEEP_MONTHLY_DAYS=365
  KEEP_QUARTERLY_DAYS=730

  [ -f "$CONFIG_FILE" ] || die "Config not found: $CONFIG_FILE. Run: cp $SCRIPT_DIR/backup.conf.example $CONFIG_FILE"

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  BACKUP_DIR="$(readlink -m "$BACKUP_DIR")"
  [ "$BACKUP_DIR" != / ] || die "BACKUP_DIR must not be /"
}

# Send all output to the log file. Run by hand, it also shows on the screen.
start_logging() {
  local log_file="$BACKUP_DIR/backup.log"
  touch "$log_file"
  if [ -t 1 ]; then
    exec > >(tee -a "$log_file") 2>&1
  else
    exec >> "$log_file" 2>&1
  fi
}

# Allow only one backup at a time. The lock is released when the script exits.
take_lock() {
  exec 9> "$BACKUP_DIR/.lock"
  flock -n 9 || die "Another backup is already running (lock file: $BACKUP_DIR/.lock)"
}


# ----------------------------------------------------------------- archive

# Create and check one .tar.gz archive of a folder or file. Returns 1 on failure.
archive_path() {
  local src parent base out dir rel pattern rc=0
  local tar_opts=()

  src="$(readlink -m "$1")"                # full path, no trailing slash
  [ -e "$src" ] || { error "Path not found: $1"; return 1; }
  [ "$src" != / ] || { error "Refusing to archive /"; return 1; }
  case "$src" in
    "$BACKUP_DIR"|"$BACKUP_DIR"/*) error "Path is inside BACKUP_DIR: $src"; return 1 ;;
  esac

  parent="$(dirname "$src")"
  base="$(basename "$src")"
  out="$RUN_DIR/${TS}_${HOST}_${base}.tar.gz"
  # Two paths with the same last part (/a/data and /b/data) would share a name.
  [ ! -e "$out" ] || { error "Another path in this run is also named $base, skipping $src"; return 1; }

  # 1. Exact paths to leave out: the backups folder and EXCLUDE_PATHS.
  #    Only paths inside $src matter. tar wants them relative to $parent.
  tar_opts+=(--anchored --no-wildcards)
  for dir in "$BACKUP_DIR" "${EXCLUDE_PATHS[@]}"; do
    dir="$(readlink -m "$dir")"
    case "$dir" in
      "$src"/*)
        rel="${dir#"$parent"}"
        tar_opts+=(--exclude="${rel#/}")
        log "Skipping $dir"
        ;;
    esac
  done

  # 2. Names to leave out anywhere, for example "node_modules".
  tar_opts+=(--no-anchored --wildcards)
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    tar_opts+=(--exclude="$pattern")
  done

  log "Archiving $src"
  tar -C "$parent" --warning=no-file-changed "${tar_opts[@]}" -czf "$out" "$base" || rc=$?

  # tar exit code 1 means "some files changed while being read", for example
  # log files. The archive is still usable, so this is only a warning.
  if [ "$rc" -eq 1 ]; then
    warn "Some files changed while archiving $src (normal for live log files)"
  elif [ "$rc" -ne 0 ]; then
    error "tar failed for $src (exit code $rc)"
    rm -f "$out"
    return 1
  fi

  # Check the archive is not empty and can be read to the end.
  [ -s "$out" ] || { error "Archive is empty: $out"; return 1; }
  tar -tzf "$out" > /dev/null || { error "Archive is corrupt: $out"; return 1; }
  log "OK   $(du -h "$out" | cut -f1)   $out"
}

# Dump one database from a running Docker container. Returns 1 on failure.
# $1 = "<engine> <container> [user]", for example "postgres supabase-db".
# The dump tool runs inside the container and takes the password from the
# container's own environment, so no password goes in backup.conf.
dump_db() {
  local engine container user ext out cmd rc=0

  read -r engine container user _ <<< "$1"
  [ -n "$container" ] || { error "Bad DATABASES entry: '$1'. Use: \"postgres <container>\""; return 1; }

  case "$engine" in
    postgres)
      ext=sql
      cmd='export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
           exec pg_dumpall -U "${1:-${POSTGRES_USER:-postgres}}"' ;;
    mysql|mariadb)
      ext=sql
      cmd='export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"
           dump="$(command -v mariadb-dump || command -v mysqldump)"
           exec "$dump" -u "${1:-root}" --all-databases --single-transaction --routines --events' ;;
    mongo|mongodb)
      ext=archive
      cmd='set --
           [ -z "$MONGO_INITDB_ROOT_USERNAME" ] || set -- -u "$MONGO_INITDB_ROOT_USERNAME" \
             -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin
           exec mongodump --archive --quiet "$@"' ;;
    *)
      error "Unknown database engine '$engine' in '$1'. Use postgres, mysql, mariadb or mongo"
      return 1 ;;
  esac

  out="$RUN_DIR/${TS}_${HOST}_${container}.${ext}.gz"
  [ ! -e "$out" ] || { error "Container $container is listed twice in DATABASES"; return 1; }
  [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ] \
    || { error "Container is not running: $container (see: docker ps)"; return 1; }

  log "Dumping $engine database in container $container"
  docker exec "$container" sh -c "$cmd" sh "$user" | gzip > "$out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    error "Dump failed for $container (exit code $rc). The error is above."
    rm -f "$out"
    return 1
  fi

  # Check the file can be read to the end and is not an empty dump.
  gzip -t "$out" || { error "Dump is corrupt: $out"; return 1; }
  [ "$(gzip -cd "$out" | head -c 1 | wc -c)" = 1 ] || { error "Dump is empty: $out"; rm -f "$out"; return 1; }
  log "OK   $(du -h "$out" | cut -f1)   $out"
}

# Delete run folders older than N days. $1 = daily|weekly|..., $2 = days to keep.
delete_old() {
  local dir="$BACKUP_DIR/$1"
  [ -d "$dir" ] || return 0
  log "Deleting $1 backups older than $2 days"
  find "$dir" -mindepth 1 -maxdepth 1 -type d -mtime +"$2" -print -exec rm -rf {} +
}


# ----------------------------------------------------------------- main

TYPE="${1:-}"
case "$TYPE" in
  daily|weekly|monthly|quarterly) ;;
  *) echo "Usage: sudo $0 daily|weekly|monthly|quarterly" >&2; exit 2 ;;
esac

for cmd in tar gzip flock find stat readlink du cut getent; do
  command -v "$cmd" > /dev/null 2>&1 || die "Required command not found: $cmd"
done

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"
OWNER="$(stat -c '%U' "$SCRIPT_DIR")"    # the user who cloned the repo
USER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
[ -n "$USER_HOME" ] || die "Could not find the home folder of $OWNER"

[ "$(id -u)" = 0 ] || warn "Not running as root. Files you cannot read will fail. Use: sudo $0 $TYPE"

load_config

HOST="$(uname -n)"
HOST="${HOST%%.*}"
TS="$(date +%F_%H%M%S)"
RUN_DIR="$BACKUP_DIR/$TYPE/${TS%_*}"
mkdir -p "$RUN_DIR"

start_logging
take_lock

declare -n paths="${TYPE^^}_PATHS"       # daily -> DAILY_PATHS
[ "${#paths[@]}" -gt 0 ] || [ "${#DATABASES[@]}" -gt 0 ] \
  || die "Nothing to back up. Set ${TYPE^^}_PATHS or DATABASES in $CONFIG_FILE"
[ "${#DATABASES[@]}" -eq 0 ] || command -v docker > /dev/null 2>&1 \
  || die "DATABASES is set but the docker command was not found"

log "===== $TYPE backup started on $HOST ====="
FAILED=0
# Databases first, so their dumps are as close to the start time as possible.
for db in "${DATABASES[@]}"; do
  dump_db "$db" || FAILED=$((FAILED + 1))
done
for p in "${paths[@]}"; do
  archive_path "$p" || FAILED=$((FAILED + 1))
done

# Root made the files. Give them to the user so they can copy them off the server.
[ "$(id -u)" != 0 ] || chown -R "$OWNER:" "$BACKUP_DIR"

if [ "$FAILED" -eq 0 ]; then
  delete_old daily "$KEEP_DAILY_DAYS"
  delete_old weekly "$KEEP_WEEKLY_DAYS"
  delete_old monthly "$KEEP_MONTHLY_DAYS"
  delete_old quarterly "$KEEP_QUARTERLY_DAYS"
  log "===== $TYPE backup finished OK ====="
else
  die "===== $FAILED backup(s) failed. Old backups were kept. ====="
fi
