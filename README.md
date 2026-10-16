# Linux Universal Backup

Configurable Bash backup script for filesystem paths and selected databases, with
optional `rclone` upload and local archive retention.

## Setup

```bash
cp .env.example .env
chmod 700 .env
chmod +x universal-backup.sh
```

Edit `.env` for this server, then run:

```bash
./universal-backup.sh
```

The script sources `.env` as Bash code, so only use a configuration file you
trust. `.env` is ignored by Git; commit configuration changes to `.env.example`
without putting passwords, connection strings, or other secrets in it.

Set the relevant `BACKUP_*` option to `true` to enable a backup type. Lists use
the pipe (`|`) character as a separator, for example:

```bash
BACKUP_DIRS=true
BACKUP_DIRECTORIES="/etc|/home/myuser"
```

The script requires Bash 4.3 or newer and standard Linux utilities including
`tar`, `gzip`, `find`, and `mktemp`. Database and upload features also require
their corresponding clients (`mysqldump`/`mariadb-dump`, PostgreSQL tools,
`mongodump`, `sqlite3`, or `rclone`).
