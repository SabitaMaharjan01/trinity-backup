# backups-trinity

One simple script that archives chosen folders and files on a Linux server into `.tar.gz` files, daily and weekly.

- Each configured path (a folder or a single file) becomes one `.tar.gz`.
- Leaves out the paths and names you list (for example `node_modules`).
- Checks every archive after writing it, logs everything, and exits non-zero if anything failed.
- Deletes old backups only after a fully successful run.

Works on Debian/Ubuntu and RHEL/Rocky/Alma. Needs bash 4.4+ and the usual base tools (`tar`, `gzip`, `flock`, `find`).

## Files

| File                        | What it does                                                                       |
| --------------------------- | ---------------------------------------------------------------------------------- |
| `backup.sh`                 | The backup script. Cron runs it.                                                   |
| `backup.conf.example`       | Config template. The real one lives in `/home/<user>/backups-trinity/backup.conf`. |
| `cron/root-crontab.example` | Cron lines to copy.                                                                |

## Where things live

| What    | Where                                               |
| ------- | --------------------------------------------------- |
| Code    | `/opt/backups-trinity/` (owned by root)             |
| Config  | `/home/<user>/backups-trinity/backup.conf`          |
| Log     | `/home/<user>/backups-trinity/backup.log`           |
| Backups | `/home/<user>/backups-trinity/daily/` and `weekly/` |

```
/home/ttpl/backups-trinity/
  backup.conf
  backup.log
  daily/2026-10-18/
    ttpl-vps-eu_2026-10-18_014000_home-ttpl-docker-supabase-kalas.tar.gz
  weekly/2026-10-18/
    ttpl-vps-eu_2026-10-18_034000_home-ttpl-docker.tar.gz
```

Backups and the log go next to the config file unless you set `BACKUP_ROOT` or `LOG_FILE` in it. The backups folder must be a real folder, not a link, and the script makes it owned by root.

The file name is the host, the time, and the full path with `/` turned into `-`.

Folders are `700` and files are `600`, owned by root, because they contain `.env` secrets.

The code stays in `/opt`, not in the user's home: root runs it from cron, and the user can rename or replace anything in their home folder.

## Install

Run on each server. Replace `ttpl` with the user on that server.

```bash
# 1. Get the code. Keep it owned by root: root runs this script, so anyone
#    who can edit it can run commands as root.
sudo git clone https://github.com/<you>/backups-trinity.git /opt/backups-trinity
sudo chown -R root:root /opt/backups-trinity
sudo chmod 700 /opt/backups-trinity/backup.sh

# 2. Config
sudo mkdir -p /home/ttpl/backups-trinity
sudo cp /opt/backups-trinity/backup.conf.example /home/ttpl/backups-trinity/backup.conf
sudo chown root:root /home/ttpl/backups-trinity/backup.conf
sudo chmod 600 /home/ttpl/backups-trinity/backup.conf
sudo nano /home/ttpl/backups-trinity/backup.conf    # set BASE_DIR and DAILY_PATHS at least

# 3. Test once by hand and read the output
sudo /opt/backups-trinity/backup.sh daily /home/ttpl/backups-trinity/backup.conf

# 4. Schedule it
sudo crontab -e                 # paste the lines from cron/root-crontab.example
```

Optional log rotation, saved as `/etc/logrotate.d/backups-trinity`:

```
/home/ttpl/backups-trinity/backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
```

## Usage

```bash
sudo /opt/backups-trinity/backup.sh daily  /home/ttpl/backups-trinity/backup.conf   # archives DAILY_PATHS
sudo /opt/backups-trinity/backup.sh weekly /home/ttpl/backups-trinity/backup.conf   # archives WEEKLY_PATHS
```

Exit code `0` means everything worked. Anything else means at least one archive failed. The log says which.

## Restore

Extract the archive into the folder that contained the backed-up path. As root, `tar` restores the original owners and permissions.

```bash
# Restores /home/ttpl/docker/supabase-kalas
sudo tar -xzf <host>_<time>_home-ttpl-docker-supabase-kalas.tar.gz -C /home/ttpl/docker

# Restores /home/ttpl/docker
sudo tar -xzf <host>_<time>_home-ttpl-docker.tar.gz -C /home/ttpl
```

Stop the service's containers before extracting over a running service.

## Limits you should know

- **Databases are not dumped.** A running Postgres, MySQL or MongoDB data folder is copied as it is, and that copy may not restore cleanly. SQLite files copied while the app writes to them can be inconsistent too.
- **Same-disk backups are not a backup.** If the disk or server is lost, the backups go with it. Copy them off the server.
- **Backups share the `/home` disk with your services.** If backups fill it, the services run out of space too. Watch the free space.
- **No encryption.** The files contain secrets. Encrypt before any off-site copy.
- **Named Docker volumes are not archived.** They live in `/var/lib/docker`, not in your folders, unless you list them as paths.
- **No alerts.** A failed cron run only shows in the log. Errors before the log opens (for example a wrong config path) go to cron's mail, or nowhere if the server has no mail set up.
- **Restores are only proven by testing them.** Do a test restore on a spare server regularly.

---

Managed with ❤️ by [Trinity Technology](https://trinitytech.com.np).
