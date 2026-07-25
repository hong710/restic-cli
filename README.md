# restic-cli Cheat Sheet

## Install (backup server)

```bash
sudo apt-get update
sudo apt-get install -y bash python3 rsync openssh-client restic openssl
chmod +x ./restic-cli
chmod +x ./systemd/install.sh
```

## Required Commands

```bash
./restic-cli init
./restic-cli setup
./restic-cli servers
./restic-cli remove <server_name>
./restic-cli backup
./restic-cli run-due
./restic-cli snapshots
./restic-cli diff <server_name> <snapshot_a> <snapshot_b>
./restic-cli prune <server_name>
./restic-cli restore
```

Optional target server:

```bash
./restic-cli backup web01
./restic-cli snapshots web01
./restic-cli restore web01
./restic-cli restore web01 9e6af64e
./restic-cli restore web01 --no-push
./restic-cli restore web01 9e6af64e --no-push
./restic-cli diff web01 180a5185 c0dc38a1
./restic-cli prune web01
```

## First Run

```bash
./restic-cli init
./restic-cli setup
```

`init` collects global settings used by all servers:

- backup storage path (local)
- restore storage path (local)
- log directory
- password directory
- shared password filename

Then `setup` collects server-specific settings:

- server name, host, ssh user, ssh port
- remote paths to back up

Wizard also:

- tests ssh
- installs remote restic if missing (apt)
- creates repository at BACKUP_STORAGE/server_name
- generates one shared password at passwords/shared.pass
- asks backup frequency from fixed options: once a day, once a week, every 2wk
- asks backup time in `HH:MM`
- asks backup day for weekly and 2-week schedules
- asks retention policy from fixed options: 1snapshots, 3snapshots, 5snapshots, 7snapshots
- waits up to 5 minutes for a repository lock before failing a restic operation
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
RETENTION_POLICY="7snapshots"
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
./restic-cli backup
```

Run only servers that are due by configured frequency:

```bash
./restic-cli run-due
```

Restore latest snapshot:

```bash
./restic-cli restore web01
```

Restore a specific snapshot:

```bash
./restic-cli restore web01 9e6af64e
```

Restore no-push preview (no remote writes):

```bash
./restic-cli restore web01 --no-push
./restic-cli restore web01 9e6af64e --no-push
```

Restore flow behavior:

- restores latest snapshot locally to RESTORE_STORAGE
- can restore a specific snapshot id when provided
- no-push mode restores under RESTORE_STORAGE (no-push target) and previews remote rsync changes only
- asks whether to push restored data back to remote host
- optional rsync dry-run preview
- asks for final apply confirmation before remote write
- pushes restored paths back to original remote paths over SSH

List configured backup servers:

```bash
./restic-cli servers
```

Remove server from backup list (keeps repository data):

```bash
./restic-cli remove web01
```

Show snapshots:

```bash
./restic-cli snapshots
./restic-cli snapshots web01
```

The snapshots table includes two size columns between tags and paths: data size and snapshot size.

Compare two snapshots for one server:

```bash
./restic-cli diff web01 180a5185 c0dc38a1
```

Prune older identical snapshots for one server:

```bash
./restic-cli prune web01
```

Prune behavior:

- scans snapshots for the server and groups them by identical restic tree id
- shows older duplicate snapshots with time, files, and bytes processed
- asks for confirmation before forgetting those older identical snapshots
- runs `restic forget <ids> --prune` only after confirmation

Restore target is always under RESTORE_STORAGE:

- `RESTORE_STORAGE/web01`
- or `RESTORE_STORAGE/web01-YYYYMMDD-HHMMSS` if existing
- no-push target: `RESTORE_STORAGE/web01-dry-run`
- or `RESTORE_STORAGE/web01-dry-run-YYYYMMDD-HHMMSS` if existing

Remote push target:

- server from `servers/<name>.conf` (`USER@HOST`)
- exact original paths from `BACKUP_PATHS`

## Scheduler

Frequency choices are checked by `restic-cli run-due`:

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
It also installs the logrotate policy into `/etc/logrotate.d/restic-cli`.

Before installing systemd units, run init first (and then setup) in the same project copy used by systemd so `config.conf` and server files are populated:

```bash
./restic-cli init
./restic-cli setup
```

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

The installer reloads and restarts the timer, so `list-timers` should show a concrete next run time.

Change timer interval in `systemd/restic-scheduler.timer` at `OnCalendar=`:

- every 1 minute: `OnCalendar=*-*-* *:*:00`
- every 5 minutes: `OnCalendar=*-*-* *:0/5:00`
- every 15 minutes: `OnCalendar=*-*-* *:0/15:00`

After changing the timer file, apply it:

```bash
sudo systemctl daemon-reload
sudo systemctl restart restic-scheduler.timer
systemctl list-timers --all | grep restic-scheduler
```

The timer runs every minute and calls `./restic-cli run-due`. The script decides which servers are due and only runs those backups.

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
