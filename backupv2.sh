#!/usr/bin/env bash
# Universal configurable Linux backup engine. Keep application-specific details in .env.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
DRY_RUN=false
LIST_ONLY=false
ONLY=""
usage(){ cat <<'EOF'
Usage: backup.sh [--dry-run] [--list] [--only NAME] [--env FILE] [--help]
  --dry-run   Validate configuration and show actions without creating backups
  --list      List configured named targets
  --only NAME Run only the matching named filesystem/volume/database target
  --env FILE  Use a different .env file
EOF
}
while (($#)); do case "$1" in
  --dry-run) DRY_RUN=true; shift;; --list) LIST_ONLY=true; shift;;
  --only) (($# >= 2)) || { echo '--only needs a name' >&2; exit 2; }; ONLY="$2"; shift 2;;
  --env) (($# >= 2)) || { echo '--env needs a path' >&2; exit 2; }; ENV_FILE="$2"; shift 2;;
  -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; usage >&2; exit 2;; esac; done
[[ -r "$ENV_FILE" ]] || { echo "Cannot read config: $ENV_FILE" >&2; exit 1; }
# The administrator must control this trusted shell configuration file.
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${BACKUP_DIR:=${SCRIPT_DIR}}"; : "${BACKUP_PREFIX:=backup}"; : "${RETENTION_DAYS:=14}"
: "${BACKUP_ITEMS:=}"; : "${DOCKER_VOLUMES:=}"; : "${POSTGRES_TARGETS:=}"
: "${MYSQL_TARGETS:=}"; : "${MONGO_TARGETS:=}"; : "${SQLITE_TARGETS:=}"
: "${RCLONE_UPLOAD:=false}"; : "${RCLONE_REMOTE:=gdrive}"; : "${RCLONE_DESTINATION:=backups}"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || { echo 'RETENTION_DAYS must be an integer >= 0' >&2; exit 1; }
is_on(){ case "${1,,}" in true|yes|1|on) return 0;; false|no|0|off|'') return 1;; *) echo "Invalid boolean: $1" >&2; exit 1;; esac; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Required command missing: $1" >&2; exit 1; }; }
safe(){ printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'; }
selected(){ [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
split_semis(){ local v="$1" n="$2"; local -n out="$n"; out=(); [[ -n "$v" ]] && IFS=';' read -r -a out <<< "$v" || true; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }

# BACKUP_ITEMS: name|absolute_path;name|absolute_path
# DOCKER_VOLUMES: name|docker_volume;name|docker_volume
# POSTGRES_TARGETS: name|container|database|user|password;...
# MYSQL_TARGETS: name|container|database|user|password;...
# MONGO_TARGETS: name|container|database;... (database may be ALL; auth is configured in container)
# SQLITE_TARGETS: name|absolute_database_file;...
IFS=';' read -r -a items <<< "$BACKUP_ITEMS"
IFS=';' read -r -a volumes <<< "$DOCKER_VOLUMES"
IFS=';' read -r -a pg_targets <<< "$POSTGRES_TARGETS"
IFS=';' read -r -a my_targets <<< "$MYSQL_TARGETS"
IFS=';' read -r -a mo_targets <<< "$MONGO_TARGETS"
IFS=';' read -r -a sq_targets <<< "$SQLITE_TARGETS"
if [[ "$LIST_ONLY" == true ]]; then
  for group in items volumes pg_targets my_targets mo_targets sq_targets; do
    local_dummy=""
    declare -n arr="$group"
    for entry in "${arr[@]}"; do [[ -n "$entry" ]] && printf '%s: %s\n' "$group" "${entry%%|*}"; done
    unset -n arr
  done
  exit 0
fi
mkdir -p -- "$BACKUP_DIR"
BACKUP_DIR="$(cd -- "$BACKUP_DIR" && pwd)"
LOG_FILE="${LOG_FILE:-${BACKUP_DIR}/backup.log}"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE" 2>/dev/null || true
HOST="$(hostname -s 2>/dev/null || hostname)"; HOST="$(safe "$HOST")"
TS="$(date '+%Y-%m-%d_%H-%M-%S')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/universal-backup.XXXXXX")"
cleanup(){ rm -rf -- "$WORK"; }
trap cleanup EXIT
log "Starting universal backup; host=$HOST; config=$ENV_FILE; dry_run=$DRY_RUN"

archive_path(){
  local name="$1" path="$2" out tmp
  name="$(safe "$name")"; out="${BACKUP_DIR}/${HOST}_${name}-${TS}.tar.gz"
  [[ -e "$path" ]] || fail "Configured path does not exist: $path"
  local resolved_path resolved_backup
  resolved_path="$(realpath -e -- "$path")" || fail "Cannot resolve backup path: $path"
  resolved_backup="$(realpath -m -- "$BACKUP_DIR")" || fail "Cannot resolve backup destination: $BACKUP_DIR"
  [[ "$resolved_path" != "$resolved_backup" && "$resolved_path" != "$resolved_backup/"* && "$resolved_backup" != "$resolved_path/"* ]] || fail "Refusing recursive/overlapping backup path: $path"
  if [[ "$DRY_RUN" == true ]]; then log "Would archive $path -> $out"; return; fi
  need tar; tmp="$(mktemp "${BACKUP_DIR}/.${HOST}_${name}.XXXXXX")"
  if [[ "$path" == "/home/barista/docker" ]]; then
  if ! tar --exclude='home/barista/docker/mattermost/volumes/db/var/lib/postgresql/data' \
            --exclude='home/barista/docker/twenty/volumes/db/data' \
            -czf "$tmp" -C / "${path#/}"; then
    rm -f "$tmp"
    fail "Archive failed: $path"
  fi
else
  if ! tar -czf "$tmp" -C / "${path#/}"; then
    rm -f "$tmp"
    fail "Archive failed: $path"
  fi
fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Empty archive: $path"; }
  tar -tzf "$tmp" >/dev/null || { rm -f "$tmp"; fail "Archive validation failed: $path"; }
  mv -- "$tmp" "$out"; chmod 600 "$out"; sha256sum "$out" > "$out.sha256"; chmod 600 "$out.sha256"
  log "Created and verified $out"
}
for entry in "${items[@]}"; do
  [[ -n "$entry" ]] || continue; [[ "$entry" == *'|'* ]] || fail "Invalid BACKUP_ITEMS entry: $entry"
  name="${entry%%|*}"; path="${entry#*|}"; selected "$name" && archive_path "$name" "$path"
done
for entry in "${volumes[@]}"; do
  [[ -n "$entry" ]] || continue; [[ "$entry" == *'|'* ]] || fail "Invalid DOCKER_VOLUMES entry: $entry"
  name="${entry%%|*}"; vol="${entry#*|}"; selected "$name" || continue
  need docker; docker volume inspect "$vol" >/dev/null 2>&1 || fail "Docker volume not found: $vol"
  out="${BACKUP_DIR}/${HOST}_$(safe "$name")-${TS}.tar.gz"
  if [[ "$DRY_RUN" == true ]]; then log "Would archive Docker volume $vol -> $out"; continue; fi
  tmp="$(mktemp "${BACKUP_DIR}/.volume.XXXXXX")"
  if ! docker run --rm -v "$vol:/volume:ro" -v "$WORK:/out" alpine:3.20 sh -c 'tar -czf /out/volume.tar.gz -C /volume .' >/dev/null; then rm -f "$tmp"; fail "Docker volume archive failed: $vol (requires Docker access and alpine image)"; fi
  cp "$WORK/volume.tar.gz" "$tmp"; [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Empty volume archive: $vol"; }
  tar -tzf "$tmp" >/dev/null || { rm -f "$tmp"; fail "Volume archive validation failed: $vol"; }
  mv "$tmp" "$out"; chmod 600 "$out"; sha256sum "$out" > "$out.sha256"; chmod 600 "$out.sha256"; rm -f "$WORK/volume.tar.gz"
  log "Created and verified Docker volume backup $out"
done
for entry in "${pg_targets[@]}"; do
  [[ -n "$entry" ]] || continue; IFS='|' read -r name container db user pass <<< "$entry"
  [[ -n "${name:-}" && -n "${container:-}" && -n "${db:-}" && -n "${user:-}" ]] || fail "PostgreSQL target must be name|container|database|user|password: $entry"
  selected "$name" || continue; need docker
  out="${BACKUP_DIR}/${HOST}_$(safe "$name")-${TS}.dump"
  if [[ "$DRY_RUN" == true ]]; then log "Would pg_dump database '$db' from container '$container' -> $out"; continue; fi
  tmp="$(mktemp "${BACKUP_DIR}/.pgdump.XXXXXX")"
  if ! docker exec -e "PGPASSWORD=${pass:-}" "$container" pg_dump -U "$user" -d "$db" -Fc > "$tmp"; then rm -f "$tmp"; fail "PostgreSQL dump failed: $name ($container/$db)"; fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Empty PostgreSQL dump: $name"; }
  mv "$tmp" "$out"; chmod 600 "$out"; sha256sum "$out" > "$out.sha256"; chmod 600 "$out.sha256"; log "Created PostgreSQL dump $out"
done
for entry in "${my_targets[@]}"; do
  [[ -n "$entry" ]] || continue; IFS='|' read -r name container db user pass <<< "$entry"
  [[ -n "${name:-}" && -n "${container:-}" && -n "${db:-}" && -n "${user:-}" ]] || fail "MySQL target must be name|container|database|user|password: $entry"
  selected "$name" || continue; need docker
  out="${BACKUP_DIR}/${HOST}_$(safe "$name")-${TS}.sql.gz"
  if [[ "$DRY_RUN" == true ]]; then log "Would dump MySQL database '$db' from '$container' -> $out"; continue; fi
  tmp="$(mktemp "${BACKUP_DIR}/.mysqldump.XXXXXX")"
  if ! docker exec -e "MYSQL_PWD=${pass:-}" "$container" sh -c 'exec mysqldump -u "$1" --single-transaction --routines --events --triggers "$2"' sh "$user" "$db" | gzip -c > "$tmp"; then rm -f "$tmp"; fail "MySQL dump failed: $name"; fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Empty MySQL dump: $name"; }
  gzip -t "$tmp" || { rm -f "$tmp"; fail "Invalid gzip dump: $name"; }
  mv "$tmp" "$out"; chmod 600 "$out"; sha256sum "$out" > "$out.sha256"; chmod 600 "$out.sha256"; log "Created MySQL dump $out"
done
for entry in "${mo_targets[@]}"; do
  [[ -n "$entry" ]] || continue; IFS='|' read -r name container db <<< "$entry"
  [[ -n "${name:-}" && -n "${container:-}" && -n "${db:-}" ]] || fail "Mongo target must be name|container|database: $entry"
  selected "$name" || continue; need docker
  out="${BACKUP_DIR}/${HOST}_$(safe "$name")-${TS}.archive.gz"
  if [[ "$DRY_RUN" == true ]]; then log "Would mongodump '$db' from '$container' -> $out"; continue; fi
  tmp="$(mktemp "${BACKUP_DIR}/.mongodump.XXXXXX")"
  if [[ "$db" == ALL ]]; then docker exec "$container" sh -c 'mongodump --archive --gzip' > "$tmp" || { rm -f "$tmp"; fail "MongoDB dump failed: $name"; }
  else docker exec "$container" sh -c 'mongodump --db="$1" --archive --gzip' sh "$db" > "$tmp" || { rm -f "$tmp"; fail "MongoDB dump failed: $name"; }; fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Empty MongoDB dump: $name"; }
  mv "$tmp" "$out"; chmod 600 "$out"; sha256sum "$out" > "$out.sha256"; chmod 600 "$out.sha256"; log "Created MongoDB dump $out"
done
for entry in "${sq_targets[@]}"; do
  [[ -n "$entry" ]] || continue; [[ "$entry" == *'|'* ]] || fail "SQLite target must be name|absolute_path: $entry"
  name="${entry%%|*}"; db="${entry#*|}"; selected "$name" || continue
  [[ -f "$db" ]] || fail "SQLite database file not found: $db"; need sqlite3
  out="${BACKUP_DIR}/${HOST}_$(safe "$name")-${TS}.sqlite"
  if [[ "$DRY_RUN" == true ]]; then log "Would SQLite-backup $db -> $out"; continue; fi
  tmp="$(mktemp "${BACKUP_DIR}/.sqlite.XXXXXX")"
  sqlite3 "$db" ".backup '$tmp'" || { rm -f "$tmp"; fail "SQLite backup failed: $name"; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fail "Empty SQLite backup: $name"; }
  mv "$tmp" "$out"; chmod 600 "$out"; sha256sum "$out" > "$out.sha256"; chmod 600 "$out.sha256"; log "Created SQLite backup $out"
done

if [[ "$DRY_RUN" == true ]]; then log 'Dry run complete; no backups created.'; exit 0; fi
if is_on "$RCLONE_UPLOAD"; then
  need rclone; remote="${RCLONE_REMOTE}:${RCLONE_DESTINATION%/}"
  # Upload only backup files created in this run (same timestamp).
  shopt -s nullglob
  for f in "$BACKUP_DIR/${HOST}_*-${TS}.tar.gz" "$BACKUP_DIR/${HOST}_*-${TS}.dump" "$BACKUP_DIR/${HOST}_*-${TS}.sql.gz" "$BACKUP_DIR/${HOST}_*-${TS}.archive.gz" "$BACKUP_DIR/${HOST}_*-${TS}.sqlite"; do
    [[ -f "$f" ]] || continue; rclone copyto "$f" "$remote/$(basename "$f")" || fail "rclone upload failed: $f"
    [[ -f "$f.sha256" ]] && rclone copyto "$f.sha256" "$remote/$(basename "$f").sha256" || true
  done
fi
if (( RETENTION_DAYS > 0 )); then
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "${HOST}_*-20??-??-??_??-??-??.tar.gz" -o -name "${HOST}_*-20??-??-??_??-??-??.dump" -o -name "${HOST}_*-20??-??-??_??-??-??.sql.gz" -o -name "${HOST}_*-20??-??-??_??-??-??.archive.gz" -o -name "${HOST}_*-20??-??-??_??-??-??.sqlite" \) -mtime "+${RETENTION_DAYS}" -print0 |
    while IFS= read -r -d '' old; do log "Removing expired backup: $old"; rm -f -- "$old" "$old.sha256"; done
fi
log 'Universal backup run completed.'