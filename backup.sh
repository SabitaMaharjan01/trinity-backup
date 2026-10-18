#!/usr/bin/env bash
#
# backup.sh: archive the folders and files listed in the config.
#
# Usage:   backup.sh daily|weekly <config-file>
# Example: backup.sh daily /home/ttpl/backups-trinity/backup.conf
#   daily  archives every path in DAILY_PATHS
#   weekly archives every path in WEEKLY_PATHS
#
# Everything lives in the folder that holds the config file:
#   /home/ttpl/backups-trinity/
#     backup.conf
#     backup.log
#     daily/<YYYY-MM-DD>/<host>_<YYYY-MM-DD_HHMMSS>_<path>.tar.gz
#     weekly/<YYYY-MM-DD>/...
#
# Each path (a folder or a single file) becomes one .tar.gz file. Example:
#   /home/ttpl/docker/supabase-kalas
#   -> ttpl-vps-eu_2026-10-18_014000_home-ttpl-docker-supabase-kalas.tar.gz
#
# Restore: sudo tar -xzf <file>.tar.gz -C <folder that contained the path>
#
# Old run folders are deleted only after a run where every archive worked.
#
# This script does NOT dump databases. A database folder that is in use is
# copied as it is, and that copy may not restore cleanly.

set -euo pipefail
umask 077    # everything we create is private to root: files 600, folders 700


# ----------------------------------------------------------------- logging

log()   { echo "$(date '+%F %T') [INFO]  $*"; }
warn()  { echo "$(date '+%F %T') [WARN]  $*" >&2; }
error() { echo "$(date '+%F %T') [ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }


# ----------------------------------------------------------------- setup

# Read the config file. Values set there replace the defaults below.
load_config() {
  BACKUP_ROOT=""
  LOG_FILE=""
  DAILY_PATHS=()
  WEEKLY_PATHS=()
  EXCLUDE_PATHS=()
  EXCLUDE_PATTERNS=()
  KEEP_DAILY_DAYS=7
  KEEP_WEEKLY_DAYS=28

  [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"

  # Root runs this file, so only root may be able to change it.
  # (stat looks at a link itself, so a link planted by a user fails here too.)
  [ "$(stat -c '%u' "$CONFIG_FILE")" = 0 ] || die "$CONFIG_FILE must be owned by root"
  [ -z "$(find "$CONFIG_FILE" -perm /022)" ] || die "$CONFIG_FILE is writable by others. Run: chmod 600 $CONFIG_FILE"

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  # Default: the folder that holds the config, for example /home/ttpl/backups-trinity.
  BACKUP_ROOT="${BACKUP_ROOT:-$(dirname "$CONFIG_FILE")}"
  BACKUP_ROOT="${BACKUP_ROOT%/}"
  case "$BACKUP_ROOT" in
    /?*) ;;
    *) die "BACKUP_ROOT must be a full path, and not / (got: '$BACKUP_ROOT')" ;;
  esac
  BACKUP_ROOT="$(readlink -m "$(dirname "$BACKUP_ROOT")")/$(basename "$BACKUP_ROOT")"
  LOG_FILE="${LOG_FILE:-$BACKUP_ROOT/backup.log}"
}

# The home folder belongs to the user, so they could swap a backup folder for
# a link to somewhere else, like /etc. Refuse links so root never writes there.
check_no_links() {
  local d
  for d in "$@"; do
    [ ! -L "$d" ] || die "$d must be a real folder, not a link"
  done
}

# Send all output to the log file. Run by hand, it also shows on the screen.
start_logging() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  if [ -t 1 ]; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    exec >> "$LOG_FILE" 2>&1
  fi
}

# Allow only one backup at a time. The lock is released when the script exits.
take_lock() {
  exec 9> "$BACKUP_ROOT/.lock"
  flock -n 9 || die "Another backup is already running (lock file: $BACKUP_ROOT/.lock)"
}


# ----------------------------------------------------------------- archive

# Create and check one .tar.gz archive of a folder or file. Returns 1 on failure.
archive_path() {
  local src parent base name out dir rel pattern rc=0
  local tar_opts=()

  src="$(readlink -m "$1")"                # full path, no trailing slash
  [ -e "$src" ] || { error "Path not found: $1"; return 1; }
  [ "$src" != / ] || { error "Refusing to archive /"; return 1; }
  case "$src" in
    "$BACKUP_ROOT"|"$BACKUP_ROOT"/*) error "Path is inside BACKUP_ROOT: $src"; return 1 ;;
  esac

  parent="$(dirname "$src")"
  base="$(basename "$src")"
  name="${src#/}"
  name="${name//\//-}"                     # "home/ttpl/docker" -> "home-ttpl-docker"
  out="$RUN_DIR/${HOST}_${TS}_${name}.tar.gz"

  # 1. Exact paths to leave out: the backups folder and EXCLUDE_PATHS.
  #    Only paths inside $src matter. tar wants them relative to $parent.
  tar_opts+=(--anchored --no-wildcards)
  for dir in "$BACKUP_ROOT" "${EXCLUDE_PATHS[@]}"; do
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

# Delete run folders older than N days. $1 = daily|weekly, $2 = days to keep.
delete_old() {
  local dir="$BACKUP_ROOT/$1"
  [ -d "$dir" ] || return 0
  log "Deleting $1 backups older than $2 days"
  find "$dir" -mindepth 1 -maxdepth 1 -type d -mtime +"$2" -print -exec rm -rf {} +
}


# ----------------------------------------------------------------- main

TYPE="${1:-}"
CONFIG_FILE="${2:-}"
case "$TYPE" in
  daily|weekly) ;;
  *) echo "Usage: $0 daily|weekly <config-file>" >&2; exit 2 ;;
esac
case "$CONFIG_FILE" in
  /*) ;;
  *) echo "Give the config file as a full path, for example: $0 $TYPE /home/ttpl/backups-trinity/backup.conf" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || die "Run this as root (for example: sudo $0 $TYPE $CONFIG_FILE)"
for cmd in tar gzip flock find stat readlink du cut; do
  command -v "$cmd" > /dev/null 2>&1 || die "Required command not found: $cmd"
done

load_config

HOST="$(uname -n)"
HOST="${HOST%%.*}"
TS="$(date +%F_%H%M%S)"
RUN_DIR="$BACKUP_ROOT/$TYPE/${TS%_*}"
check_no_links "$BACKUP_ROOT" "$BACKUP_ROOT/$TYPE" "$RUN_DIR"
mkdir -p "$RUN_DIR"
chown root:root "$BACKUP_ROOT"           # so the user cannot add links inside it later
chmod 700 "$BACKUP_ROOT" "$BACKUP_ROOT/$TYPE" "$RUN_DIR"

start_logging
take_lock

if [ "$TYPE" = daily ]; then
  paths=("${DAILY_PATHS[@]}")
else
  paths=("${WEEKLY_PATHS[@]}")
fi
[ "${#paths[@]}" -gt 0 ] || die "No paths to archive. Set ${TYPE^^}_PATHS in $CONFIG_FILE"

log "===== $TYPE backup started on $HOST ====="
FAILED=0
for p in "${paths[@]}"; do
  archive_path "$p" || FAILED=$((FAILED + 1))
done

if [ "$FAILED" -eq 0 ]; then
  delete_old daily "$KEEP_DAILY_DAYS"
  delete_old weekly "$KEEP_WEEKLY_DAYS"
  log "===== $TYPE backup finished OK ====="
else
  die "===== $FAILED archive(s) failed. Old backups were kept. ====="
fi
