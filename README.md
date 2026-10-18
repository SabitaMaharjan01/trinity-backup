# trinity-backup

One simple script that backs up a Linux server's folders, files and Docker databases, daily, weekly, monthly and quarterly. You install it on each server with `git clone` and update it with `git pull`. After that, you only edit `backup.conf`.

- Each configured path (a folder or a single file) becomes one `.tar.gz`.
- Each Postgres, MySQL/MariaDB or MongoDB container you list is dumped to a `.gz` file on every run.
- Leaves out the paths and names you list (for example `node_modules`).
- Checks every archive after writing it, logs everything, and exits non-zero if anything failed.
- Deletes old backups only after a fully successful run.

Works on Debian/Ubuntu and RHEL/Rocky/Alma. Needs bash 4.4+ and the usual base tools (`tar`, `gzip`, `flock`, `find`).

## How it works

Clone the repo into the user's home folder. Root's cron runs the script from there, and the backups land in `~/backups`:

```
/home/ttpl/
  trinity-backup/           <- this repo (git pull to update)
    backup.sh
    backup.conf             <- your settings, not tracked by git
  backups/                  <- created by the script
    backup.log
    daily/2026-10-18/
      2026-10-18_014000_ttpl-vps-eu_supabase-db.sql.gz      <- database dump
      2026-10-18_014000_ttpl-vps-eu_supabase-kalas.tar.gz   <- folder archive
    weekly/2026-10-18/
      2026-10-18_034000_ttpl-vps-eu_docker.tar.gz
    monthly/2026-10-01/
      2026-10-01_054000_ttpl-vps-eu_docker.tar.gz
    quarterly/2026-10-01/
      2026-10-01_074000_ttpl-vps-eu_docker.tar.gz
```

- **The user** is whoever owns the `trinity-backup` folder. The script finds their home folder by itself, so the same `backup.conf` works on every server.
- **Root** runs the script so it can read every file, including Docker data owned by other users.
- **The backups** are given back to the user when the run ends (files `600`, folders `700`), so the user can copy them off the server without sudo.
- **The file name** is the date and time, the host, and the last part of the path: `/home/ttpl/docker/uptime-kuma` becomes `2026-10-18_150221_milkyway_uptime-kuma.tar.gz`. Two paths with the same last part in one run (like `/a/data` and `/b/data`) clash, so the second one fails. Back up their parent folder instead. A database dump is named after its container instead.

## Files

| File                     | What it does                                       |
| ------------------------ | -------------------------------------------------- |
| `backup.sh`              | The backup script. Cron runs it.                   |
| `backup.conf.example`    | Config template. Copy it to `backup.conf`.         |
| `cron/crontab.example`   | Cron lines to paste into root's crontab.           |

## Install

Run on each server **as the normal user** (not with sudo, so the repo belongs to them). Replace `ttpl` with that user.

```bash
# 1. Get the code
cd ~
git clone https://github.com/<you>/trinity-backup.git
cd trinity-backup

# 2. Config: say what to back up
cp backup.conf.example backup.conf
nano backup.conf

# 3. Test once by hand and read the output
sudo ./backup.sh daily

# 4. Schedule it in root's crontab
sudo crontab -e                 # paste the lines from cron/crontab.example
```

## Usage

```bash
sudo ~/trinity-backup/backup.sh daily       # archives DAILY_PATHS
sudo ~/trinity-backup/backup.sh weekly      # archives WEEKLY_PATHS
sudo ~/trinity-backup/backup.sh monthly     # archives MONTHLY_PATHS
sudo ~/trinity-backup/backup.sh quarterly   # archives QUARTERLY_PATHS
```

The example cron schedule:

| Run         | When                                         | Kept for (default) |
| ----------- | -------------------------------------------- | ------------------ |
| `daily`     | Every day at 01:40                           | 7 days             |
| `weekly`    | Sundays at 03:40                             | 28 days            |
| `monthly`   | 1st of every month at 05:40                  | 365 days           |
| `quarterly` | 1st of January, April, July, October at 07:40 | 730 days           |

Runs are two hours apart so they don't overlap. Only one backup runs at a time. If a run starts while another is still going, it stops with a lock error and that backup is skipped.

Every run also dumps every database in `DATABASES`.

Exit code `0` means everything worked. Anything else means at least one archive or dump failed. `~/backups/backup.log` says which.

## Configure

Everything is in `backup.conf`. Use `$USER_HOME` instead of `~`, because under sudo or cron `~` means `/root`.

| Setting                          | What it means                                         |
| -------------------------------- | ----------------------------------------------------- |
| `DAILY_PATHS`                    | Folders and files the daily run archives.             |
| `WEEKLY_PATHS`                   | Folders and files the weekly run archives.            |
| `MONTHLY_PATHS`                  | Folders and files the monthly run archives.           |
| `QUARTERLY_PATHS`                | Folders and files the quarterly run archives.         |
| `DATABASES`                      | Database containers dumped on every run. See below.   |
| `EXCLUDE_PATHS`                  | Exact folders or files to leave out.                  |
| `EXCLUDE_PATTERNS`               | Names to leave out anywhere, like `node_modules`.     |
| `KEEP_DAILY_DAYS`                | Days to keep daily backups (default 7).               |
| `KEEP_WEEKLY_DAYS`               | Days to keep weekly backups (default 28).             |
| `KEEP_MONTHLY_DAYS`              | Days to keep monthly backups (default 365).           |
| `KEEP_QUARTERLY_DAYS`            | Days to keep quarterly backups (default 730).         |
| `BACKUP_DIR`                     | Optional. Where backups go. Default `$USER_HOME/backups`. |

### Databases

Copying a running database's data folder gives a copy that may not restore. A dump is a clean snapshot, so list each database container in `DATABASES`:

```bash
DATABASES=(
  "postgres supabase-db supabase_admin"   # <engine> <container> [user]
  "mariadb  frappe_docker-db-1"
  "mongo    my-mongo"
)
```

- **engine:** `postgres`, `mysql`, `mariadb` or `mongo`.
- **container:** the name from `sudo docker ps --format '{{.Names}}'`.
- **user:** optional. Postgres uses the container's `$POSTGRES_USER`, or `postgres`. MySQL/MariaDB uses `root`. Supabase needs `supabase_admin`.

The dump runs inside the container (`pg_dumpall`, `mariadb-dump`/`mysqldump`, `mongodump`) and dumps every database in it. Passwords come from the container's own environment variables, so none go in `backup.conf`:

| Engine          | Variables it reads                                           |
| --------------- | ------------------------------------------------------------ |
| `postgres`      | `POSTGRES_PASSWORD`                                          |
| `mysql/mariadb` | `MYSQL_ROOT_PASSWORD` or `MARIADB_ROOT_PASSWORD`             |
| `mongo`         | `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD` |

The official images set these from your `docker-compose.yml`. A container that isn't running, a failed dump or an empty dump makes the run fail.

The folder archives still include each database's data folder. Once the database is dumped, add that folder to `EXCLUDE_PATHS` to save space.

## Update

```bash
cd ~/trinity-backup
git pull
```

`git pull` never touches `backup.conf` or your backups. If a new version adds settings, compare your config with `backup.conf.example`.

Run git as the normal user, not with sudo, so the files stay owned by them.

## Restore

Extract the archive into the folder that contained the backed-up path. As root, `tar` restores the original owners and permissions.

```bash
# Restores /home/ttpl/docker/supabase-kalas
sudo tar -xzf <date>_<time>_<host>_supabase-kalas.tar.gz -C /home/ttpl/docker

# Restores /home/ttpl/docker
sudo tar -xzf <date>_<time>_<host>_docker.tar.gz -C /home/ttpl
```

Stop the service's containers before extracting over a running service.

### Restore a database

Restore into a freshly started, empty database container. Start only the database container, not the app. Replace `<container>` with its name.

```bash
# Postgres
gunzip -c <file>.sql.gz | sudo docker exec -i <container> \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -U postgres -d postgres'

# MySQL / MariaDB
gunzip -c <file>.sql.gz | sudo docker exec -i <container> \
  sh -c 'export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"; exec "$(command -v mariadb || command -v mysql)" -u root'

# MongoDB (add --drop to replace collections that already exist)
gunzip -c <file>.archive.gz | sudo docker exec -i <container> \
  sh -c 'exec mongorestore --archive -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'
```

For Postgres, use the same user as in `DATABASES` (`supabase_admin` for Supabase). Messages like "role already exists" are normal.

## Optional: log rotation

Save as `/etc/logrotate.d/trinity-backup`:

```
/home/ttpl/backups/backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
```

## Limits you should know

- **The user can become root.** Root runs `backup.sh` and `backup.conf` from the user's home, so anyone who can edit them can run commands as root. Only use this on servers where that user is already trusted with sudo.
- **Only listed Docker databases are dumped.** A database that isn't in `DATABASES`, or isn't in Docker, is only copied as files, and that copy may not restore cleanly. SQLite files (for example Uptime Kuma's) are copied as files too, and can be inconsistent if the app writes to them during the backup.
- **Same-disk backups are not a backup.** If the disk or server is lost, the backups go with it. Copy them off the server.
- **Backups share the `/home` disk with your services.** If backups fill it, the services run out of space too. Watch the free space.
- **No encryption.** The files contain secrets. Encrypt before any off-site copy.
- **Named Docker volumes are not archived.** They live in `/var/lib/docker`, not in your folders, unless you list them as paths.
- **No alerts.** A failed cron run only shows in the log.
- **Restores are only proven by testing them.** Do a test restore on a spare server regularly.

---

Managed with ❤️ by [Trinity Technology](https://trinitytech.com.np).
