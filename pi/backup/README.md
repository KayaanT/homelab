# Off-box backups

## Setup

```bash
sudo tee /etc/restic-backup.env >/dev/null <<'ENV'
RESTIC_REPOSITORY=/mnt/backup/restic
RESTIC_PASSWORD_FILE=/etc/restic-password
HOMELAB_NODE=kayaan@homelab
ENV
sudo chmod 600 /etc/restic-backup.env

# a long random password - store it in a password manager, NOT on either machine
sudo tee /etc/restic-password >/dev/null <<< "$(openssl rand -base64 32)"
sudo chmod 600 /etc/restic-password
sudo restic init
```

The Pi needs passwordless SSH to the homelab node, and that account needs
passwordless `sudo` for `etcdctl`. Scope it narrowly in `/etc/sudoers.d/`.

## What this actually protects against

| Failure | Covered? |
|---|---|
| A Ceph OSD dies | No — Ceph replication handles that |
| **The SSD dies** | **Yes** — this is the point |
| `kubectl delete` on the wrong namespace | Yes |
| Ransomware / the box is compromised | Partly — add a second remote repo |
| The house burns down | No — add a cloud repo |

Restic supports multiple repositories. A second `restic backup` to Backblaze B2
costs a few dollars a year and covers the last two rows. Worth doing once the
local one is proven.

## Test the restore

An untested backup is a hope, not a backup.

```bash
restic snapshots
restic restore latest --target /tmp/restore-test
ls -la /tmp/restore-test
```

Do this **once a quarter**, and at least once before you rely on
`make rebuild`.
