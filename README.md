# backupctl Cheat Sheet

## Install (backup server)

```bash
sudo apt-get update
sudo apt-get install -y bash rsync openssh-client restic openssl
chmod +x ./backupctl
chmod +x ./systemd/install.sh
```

## Required Commands

```bash
./backupctl setup
./backupctl servers
./backupctl remove <server_name>
./backupctl backup
./backupctl run-due
./backupctl snapshots
./backupctl restore
```

Optional target server:

```bash
./backupctl backup web01
./backupctl snapshots web01
./backupctl restore web01
./backupctl restore web01 9e6af64e
./backupctl restore web01 --dry-run
./backupctl restore web01 9e6af64e --dry-run
```

## First Run

```bash
./backupctl setup
```

Wizard collects:

- server name, host, ssh user, ssh port
- backup storage path (local)
- restore storage path (local)
- remote paths to back up

Wizard also:

- tests ssh
- installs remote restic if missing (apt)
- creates repository at BACKUP_STORAGE/server_name
- generates one shared password at passwords/shared.pass
- asks backup frequency from fixed options: once a day, once a week, every 2wk
- asks backup time in `HH:MM`
- asks backup day for weekly and 2-week schedules
- asks retention policy from fixed options: 7days, 14days, 30days
- writes servers/server_name.conf

## Config Files

`config.conf`

```bash
BACKUP_STORAGE=/home/data/backups
RESTORE_STORAGE=/home/data/restore
LOG_DIRECTORY=/home/sdb/dev/restic_backup/logs
PASSWORD_DIRECTORY=/home/sdb/dev/restic_backup/passwords
SHARED_PASSWORD_FILE=shared.pass
```

`servers/web01.conf`

```bash
NAME="web01"
HOST="192.168.1.10"
USER="root"
SSH_PORT="22"
REPOSITORY="web01"
BACKUP_PATHS="
/etc
/home
/var/www
"
BACKUP_FREQUENCY="once a day"
BACKUP_TIME="02:00"
BACKUP_DAY=""
BACKUP_ANCHOR_DATE=""
RETENTION_POLICY="30days"
```

Weekly example:

```bash
BACKUP_FREQUENCY="once a week"
BACKUP_TIME="02:00"
BACKUP_DAY="Sun"
BACKUP_ANCHOR_DATE=""
```

Every 2 weeks example:

```bash
BACKUP_FREQUENCY="every 2wk"
BACKUP_TIME="02:00"
BACKUP_DAY="Sun"
BACKUP_ANCHOR_DATE="2026-07-22"
```

## Daily Ops

Run all backups:

```bash
./backupctl backup
```

Run only servers that are due by configured frequency:

```bash
./backupctl run-due
```

Restore latest snapshot:

```bash
./backupctl restore web01
```

Restore a specific snapshot:

```bash
./backupctl restore web01 9e6af64e
```

Restore dry-run preview (no remote writes):

```bash
./backupctl restore web01 --dry-run
./backupctl restore web01 9e6af64e --dry-run
```

Restore flow behavior:

- restores latest snapshot locally to RESTORE_STORAGE
- can restore a specific snapshot id when provided
- dry-run mode restores to a temporary local target and previews remote rsync changes only
- asks whether to push restored data back to remote host
- optional rsync dry-run preview
- asks for final apply confirmation before remote write
- pushes restored paths back to original remote paths over SSH

List configured backup servers:

```bash
./backupctl servers
```

Remove server from backup list (keeps repository data):

```bash
./backupctl remove web01
```

Show snapshots:

```bash
./backupctl snapshots
./backupctl snapshots web01
```

Restore target is always under RESTORE_STORAGE:

- `RESTORE_STORAGE/web01`
- or `RESTORE_STORAGE/web01-YYYYMMDD-HHMMSS` if existing

Remote push target:

- server from `servers/<name>.conf` (`USER@HOST`)
- exact original paths from `BACKUP_PATHS`

## Scheduler

Frequency choices are checked by `backupctl run-due`:

- `once a day`
- `once a week`
- `every 2wk`

Schedule rules:

- `once a day` runs at the configured `BACKUP_TIME`
- `once a week` runs on `BACKUP_DAY` at `BACKUP_TIME`
- `every 2wk` runs every 14 days from `BACKUP_ANCHOR_DATE`, on `BACKUP_DAY` at `BACKUP_TIME`

Last successful backup time is tracked under `logs/scheduler/`.

Systemd files are provided in `systemd/`:

- `systemd/restic-scheduler.service`
- `systemd/restic-scheduler.timer`
- `systemd/install.sh`

`systemd/install.sh` copies those two unit files into `/etc/systemd/system/`.
It also installs the logrotate policy into `/etc/logrotate.d/restic-backupctl`.

Install them:

```bash
sudo ./systemd/install.sh -i
```

Remove them:

```bash
sudo ./systemd/install.sh -rm
```

Check timer status:

```bash
systemctl status restic-scheduler.timer
systemctl list-timers --all | grep restic-scheduler
journalctl -u restic-scheduler.service
```

The timer runs every minute and calls `./backupctl run-due`. The script decides which servers are due and only runs those backups.

## Logs

- main: `logs/backup.log`
- backup run: `logs/backup-web01-YYYYMMDD-HHMMSS.log`
- restore run: `logs/restore-web01-YYYYMMDD-HHMMSS.log`

Log rotation:

- installed automatically by `./systemd/install.sh -i`
- rotates daily
- keeps 30 rotations
- compresses old logs
- leaves `logs/scheduler/*.last_success` untouched

## Quick Checks

SSH:

```bash
ssh -p 22 root@192.168.1.10
```

Restic repository health:

```bash
restic -r /home/data/backups/web01 --password-file ./passwords/shared.pass check
```
