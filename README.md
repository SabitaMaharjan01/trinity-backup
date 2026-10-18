# trinity-backup

Backs up a Linux server's folders, files and Docker databases on a daily,
weekly, monthly and quarterly schedule. Everything (the script, its config,
the backups and the log) lives in one folder: `~/backups`.

- Each folder or file you list becomes one `.tar.gz`.
- Each Postgres, MySQL/MariaDB or MongoDB container you list is dumped.
- Every archive is checked after it is written.
- Old backups are deleted only after a fully successful run.

Works on Debian/Ubuntu and RHEL/Rocky/Alma (bash 4.4+, tar, gzip, flock).

## Install

Run as your normal user, not with sudo:

```bash
cd ~
git clone https://github.com/SabitaMaharjan01/trinity-backup.git backups
cd ~/backups

cp backup.conf.example backup.conf
nano backup.conf                  # say what to back up

sudo ./backup.sh daily            # test once and read the output
sudo crontab -e                   # paste the lines from cron/crontab.example
```

If you get `Permission denied`, make the script executable:

```bash
chmod +x ~/backups/backup.sh
```

## Folder layout

```
~/backups/
├── backup.sh                 the script
├── backup.conf               your settings (not tracked by git)
├── backup.conf.example       config template
├── cron/crontab.example      lines for root's crontab
├── backup.log                created by the script
├── daily/2026-10-18/
│   ├── 2026-10-18_014000_myserver_supabase-db.sql.gz
│   └── 2026-10-18_014000_myserver_myapp.tar.gz
├── weekly/2026-10-18/
├── monthly/2026-10-01/
└── quarterly/2026-10-01/
```

Backups are named `<date>_<time>_<host>_<name>`. The name is the last part
of the path (`~/docker/myapp` gives `myapp`) or the database container name.

`git pull` never touches `backup.conf`, the backups or the log.

## Usage

```bash
sudo ~/backups/backup.sh daily        # archives DAILY_PATHS
sudo ~/backups/backup.sh weekly       # archives WEEKLY_PATHS
sudo ~/backups/backup.sh monthly      # archives MONTHLY_PATHS
sudo ~/backups/backup.sh quarterly    # archives QUARTERLY_PATHS
```

Every run also dumps every database in `DATABASES`.

| Run       | Cron schedule           | Kept for |
| --------- | ----------------------- | -------- |
| daily     | every day, 01:40        | 7 days   |
| weekly    | Sundays, 03:40          | 28 days  |
| monthly   | 1st of the month, 05:40 | 365 days |
| quarterly | 1st of Jan/Apr/Jul/Oct  | 730 days |

Only one backup runs at a time. Exit code `0` means everything worked.
Anything else means something failed, and `~/backups/backup.log` says what.

## Configure

Edit `~/backups/backup.conf`. Write `$USER_HOME` instead of `~`, because
under sudo or cron `~` means `/root`.

| Setting            | Meaning                                      |
| ------------------ | -------------------------------------------- |
| `DAILY_PATHS`      | Folders and files the daily run archives     |
| `WEEKLY_PATHS`     | Same, for the weekly run                     |
| `MONTHLY_PATHS`    | Same, for the monthly run                    |
| `QUARTERLY_PATHS`  | Same, for the quarterly run                  |
| `DATABASES`        | Database containers, dumped on every run     |
| `EXCLUDE_PATHS`    | Exact folders or files to leave out          |
| `EXCLUDE_PATTERNS` | Names to leave out anywhere (`node_modules`) |
| `KEEP_*_DAYS`      | How long to keep each kind of backup         |

### Databases

Copying a live database folder may not restore. List each database
container so it gets a proper dump:

```bash
DATABASES=(
  "postgres supabase-db supabase_admin"   # <engine> <container> [user]
  "mariadb  frappe_docker-db-1"
  "mongo    my-mongo"
)
```

- engine: `postgres`, `mysql`, `mariadb` or `mongo`
- container: from `sudo docker ps --format '{{.Names}}'`
- user: optional (Supabase needs `supabase_admin`)

Passwords are read from the container's own environment
(`POSTGRES_PASSWORD`, `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD`,
`MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD`), so none go
in `backup.conf`.

## Update

```bash
cd ~/backups && git pull
```

Run git as your normal user, not with sudo. If a new version adds settings,
compare `backup.conf` with `backup.conf.example`.

## Restore

Files: extract into the folder that held the backed-up path.

```bash
sudo tar -xzf ~/backups/daily/<date>/<file>_myapp.tar.gz -C ~/docker
```

Databases: start only the database container (empty, not the app), then:

```bash
# Postgres
gunzip -c <file>.sql.gz | sudo docker exec -i <container> \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -U postgres -d postgres'

# MySQL / MariaDB
gunzip -c <file>.sql.gz | sudo docker exec -i <container> \
  sh -c 'export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"; exec "$(command -v mariadb || command -v mysql)" -u root'

# MongoDB (add --drop to replace existing collections)
gunzip -c <file>.archive.gz | sudo docker exec -i <container> \
  sh -c 'exec mongorestore --archive -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
```

For Postgres, use the same user as in `DATABASES`. "role already exists"
messages are normal.

## Log rotation (optional)

Save as `/etc/logrotate.d/trinity-backup`, with your user name:

```
/home/alice/backups/backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
```

## Good to know

- Root runs files from `~/backups`, so whoever can edit them can act as root.
  Only use this where that user is already trusted with sudo.
- Backups on the same disk are lost with the disk. Copy them off the server.
- Backups share the disk with your services. Watch the free space.
- No encryption. Encrypt before copying off-site.
- Named Docker volumes and non-Docker databases are not dumped unless listed.
- No alerts. Failures only show in `backup.log`.
- Test a restore on a spare server regularly.

---

Managed with ❤️ by [Trinity Technology](https://trinitytech.com.np).
