# zfs-snapshot-all — essentials

Polish version: [ESENCJA.md](../pl/ESENCJA.md).

The package takes ZFS snapshots, copies them to a second host (or to a disk), prunes them according to retention, and
checks that the copies are fresh. One host — the **collector** — manages everything: it creates relations, holds the
copies, sends the mails. Everything is bash, the jobs run from cron, and for daily work there is a text GUI on the
server console.

## Concepts

| concept | meaning |
|---|---|
| **relation** | a pair: the collector + a source host (or the collector alone), chosen datasets and a schedule; it has a name |
| kinds of relation | **backup** (the collector pulls copies and keeps its own history), **mirror** (the same as on the source), **local copy** (on the same host), **local / remote snapshots** (snapshots only, no copies) |
| **template** | how many snapshots to keep at each tier (hourly, daily, weekly…); the GUI offers `default`, `full`, `d7h24`, `d30h24`, `m12w4d7h24-gfs` |
| **replica** | a copy of the copy on a separate medium (USB or a second pool), once a day at night |
| **passive** (copy, replica) | carries the snapshots that already exist on the source — the state as of the newest of them, **not the current state**; a dataset without snapshots is not copied. Only the mode with its own snapshots (the copy takes a snapshot itself) gives the current state. Proxmox-reserved snapshots (`__replicate_`, `vzdump`, `__migration__`) are never taken as the newest one |
| **monitor** | checks the age of the newest snapshot and raises an alarm when copies stop arriving |

## First run

1. On the collector, as root: fetch the package and prepare the host.

   ```bash
   apt-get install -y git      # a fresh Proxmox has no git
   git clone https://github.com/AdalbertKing/zfsbackup.git /root/scripts/zfs-snapshot-all
   cd /root/scripts/zfs-snapshot-all
   ./deploy.sh --backup-user=zfsbackup
   ```

   If `/root/scripts/zfs-snapshot-all` already exists (old scripts, no `.git`), `git clone` cannot go there:
   check root's `crontab -l` for anything running from it, then move it aside, e.g.
   `mv /root/scripts/zfs-snapshot-all /root/scripts/zfs-snapshot-all.old-YYYYMMDD`. On the source the wizard checks
   the same and refuses before changing anything; it installs git on the source itself.

   One script does the same, also on a host with old scripts in that directory:
   `bash install.sh --check` (changes nothing), then `bash install.sh --move-old`
   (moves the old directory aside, saves root's crontab and repoints its lines at the moved directory).
   Fetch it with `wget -O install.sh https://raw.githubusercontent.com/AdalbertKing/zfsbackup/main/install.sh`.
   Options it does not know (`--allow-quiesce`, `--grant-datasets=...`) go to `deploy.sh`.
   The alert address, and sending through your mail provider when port 25 is blocked:
   `bash install.sh --email=you@example.com --smtp-relay=smtp.example.com:587 --smtp-user=you@example.com`
   (the password is asked for on the terminal; details: DEPLOYMENT-PROXMOX.md, "Sending through your mail provider").

   Without options `deploy.sh` delegates `rpool/data` and `rpool/ROOT/pve-1` (the Proxmox default datasets) to
   the account. On a host with other pools name your own: `./deploy.sh --backup-user=zfsbackup --grant-datasets=hdd`
   (several, comma-separated). `zfs list -H -o name` lists the datasets.

2. Start the GUI and create the first relation: **F3 Relations**, key **Ins**. The wizard asks for the kind
   of relation, the source host, the datasets, the target, the template, how many snapshots stay on the source
   and the name, shows a summary and the plan, and changes anything only after **Run**. Step by step, for
   every variant: [docs/tutorial/index.html](../tutorial/index.html).

   ```bash
   zfs-backup gui
   ```

   The collector needs SSH access to the source host as root; the wizard installs the package on the source by itself.

   The title bar shows the package version (e.g. `zfs-snapshot-all 1.0.34`).

   The GUI starts in English. For Polish: **F10** (host settings), item `language` = `pl`, or

   ```bash
   zfs-backup settings set gui.language=pl --yes
   ```

   Command output stays in English.

3. Check after an hour: **F2 Przebiegi (runs)**. There are two views, both read downward from the `now` line; running runs stand
   above the line. QUEUE (F2 opens on it): upcoming runs of the next 6 hours below the line, nearest first.
   HISTORY: finished runs of the last 72 hours below the line (result, time, reason for an error), newest first.
   Ctrl-W switches queue and history; after switching, the cursor is on the first running run, or, when
   there is none, on the first row under the line. Cron lines of one relation, task and tier that start within
   5 minutes of each other (one line per dataset) are one row, `N datasets`, with the worst result; Enter expands
   it to one row per dataset. A run that died without finishing shows as INTERRUPTED.

## Day to day

| I want to… | where |
|---|---|
| see whether the copies are up to date | F3 Relacje (relations) — the "Kopie" (copies) column |
| change datasets, schedule, retention | F3, Enter on the relation, `e` |
| pause a relation (e.g. server maintenance) | F3, Enter, F8 Pauza (pause) |
| restore data | F4 Kopie (copies), F9 Przywróć (restore) |
| browse files in a snapshot | F4 Kopie, Enter (or F4 on a run in F2) |
| add a replica on a disk | F6 Replika (replica), Ins |
| see whether a replica disk is connected, how full it is, whether a copy is running | F6: columns Disk (connected / disconnected / internal) and Used; a running copy reads `copy running since …` |
| tell the mails apart | subject: `[ZFS][REPORT]` daily summary, `[ZFS][WARNING]` warning, pool capacity, data growth, `[ZFS][ALERT]` failed run; F10 `alerts.site` (or `deploy.sh --site=NAME`) puts the installation's name in the subject and sender of every mail; without it the host's full name stands there |
| do the same from the command line | [COMMANDS.md](COMMANDS.md) |

## Where next

- [HOW-IT-WORKS.md](HOW-IT-WORKS.md) — how it works inside, in plain language;
- [DEPLOYMENT-PROXMOX.md](DEPLOYMENT-PROXMOX.md) — step-by-step deployment on two Proxmox hosts;
- [DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md](DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md) — a collector with two
  sources and a replica on USB, a chain of three hosts;
- [RESTORE-FROM-REPLICA.md](RESTORE-FROM-REPLICA.md) — restore from the replica disk;
- [PAUSE-AND-DISABLE.md](PAUSE-AND-DISABLE.md) — pausing and hard-disabling a relation;
- [COMMANDS.md](COMMANDS.md) — command cheat sheet;
- technical manual (all engine options, config, alerts): [REFERENCE.md](REFERENCE.md).
