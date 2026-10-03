# database: move the OS/data disk from `zfs_pool` to `ssd_pool`

> **Status 2026-10-04: planned, not started.** Documentation only — no repo or
> Proxmox change has been made yet. This is Phase 2 of
> [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md) applied to one
> VM, pulled forward because of the incident below.

## Why now — incident 2026-10-03 ~22:40 UTC

hofvarpnir reported its database "backing off". Postgres itself was healthy; the
shared HDD pool was not.

| Signal (Prometheus) | Before | During |
| --- | --- | --- |
| `pve-gigabyte` IO pressure | ~30 % | **89 %** |
| every guest on `zfs_pool` (unifi, jellyfin, mcp, forgejo, database) | — | 83–93 % IO pressure |
| `homelab-jellyfin` `sdb` (media, `zfs_pool`) writes | 0 | **10.4 MB/s** |
| `homelab-database` `sda` write latency | 12 ms | **208 ms** |
| `homelab-database` `sda` write IOPS | ~50 | 14 |

Trigger: the hofvarpnir 0.13.1 → 0.15.0 upgrade (`4387898`) restarted the
container, which resumed a download onto `/media` (jellyfin `scsi1`, on
`zfs_pool`). That download competes with every zvol on the same two HDDs.

Effect inside Postgres (`pg_stat_activity_count` / `_max_tx_duration`):

- 20 active hofvarpnir backends, 109 `RowExclusiveLock`s.
- 15 waiting on `Lock/tuple` (oldest 432 s), 3 on `Lock/transactionid` (154 s).
- The lock holder was in **`IO/WalSync`** for 24 s — its commit could not fsync
  WAL.
- Even read-only catalog queries via the `pghofvarpnir` MCP hit
  `statement_timeout`.

So every commit costs seconds, writers convoy behind one row, sqlx's pool
drains, the app backs off. The DB's WAL fsync sits behind media writes on the
same spindles; moving the database disk to flash removes that coupling for
**every** DB client (forgejo, romm, hofvarpnir, terraform state, appdb), not just
hofvarpnir.

(Separate, app-side: 15 writers on one tuple with `MAX_CONCURRENT_DOWNLOADS=1`
suggests 0.15.0 updates one progress/job row very frequently. Track that in the
hofvarpnir repo; this move makes it tolerable, it does not fix it.)

## Facts

| | |
| --- | --- |
| VM | `database`, `vm_id = 4323`, node `pve-gigabyte` |
| Disk | `scsi0`, 64 G, `zfs_pool` (`iac/main.tf`, `database_vm`) |
| Guest FS | btrfs via `modules/disko-config.nix` (`device = "/dev/sda"`), PGDATA `+C` (NoCoW) |
| Target | `ssd_pool` — 2× Kingston A400 mirror, `sparse 1`, `autotrim=on` |

Precedent: `woodpecker_vm` moved the same way on 2026-08-15. `tofu plan`
showed the bpg provider updates `datastore_id` **in place** (no
`# forces replacement`, `0 to destroy`) by calling Proxmox's online move-disk
API — data, NixOS install and SSH host key survive, no reinstall, no agenix
re-key. See the comment above the woodpecker `disk` block in `iac/main.tf`.

## Procedure

### 0. Preconditions

- [ ] Quiet pool. Do it when hofvarpnir is not downloading and no PBS job is
      running — the copy is bounded by the **HDD read side** (measured 50–129
      IOPS during the immich move), not the SSDs. Check:
      `rate(node_pressure_io_waiting_seconds_total{instance="pve-gigabyte"}[10m])`
      should be at its ~0.3 baseline.
- [ ] Fresh backup. `qm move-disk --delete 1` (what the API does) removes the
      source with no undo. Confirm a current PBS snapshot of VM 4323 **and** a
      logical dump:
      ```bash
      ssh database.homelab.local -- sudo ls -lt /var/backup/postgresql | head
      ```
- [ ] `ssd_pool` headroom: `pvesm status | grep ssd_pool` (64 G zvol, sparse).

### 1. Choose one path

**A. Through OpenTofu (preferred — keeps IaC truthful).** In `iac/main.tf`,
`database_vm.disk`:

```hcl
disk {
  datastore_id = "ssd_pool"
  file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
  interface    = "scsi0"
  size         = 64
}
```

Leave `file_id` as is (changing it forces replacement). Do **not** add
`file_format`/`discard` in the same change — keep the diff to `datastore_id`
so the plan stays in-place. Then:

```bash
cd iac && tofu plan    # MUST show: ~ update in-place, 0 to destroy, no "forces replacement"
tofu apply
```

If the plan shows replacement, **stop** — that would recreate the VM and wipe
the database. Fall back to B.

**B. By hand on the PVE host, then reconcile IaC.**

```bash
qm config 4323 | grep -E '^(scsi|virtio|sata|ide)[0-9]'   # confirm scsi0
time qm move-disk 4323 scsi0 ssd_pool --delete 1
```

Then make the same `datastore_id` edit in `iac/main.tf`; `tofu plan` must
come back clean (no changes).

The move is live; Postgres keeps running. Expect elevated latency during the
copy. If it crawls at single-digit MB/s, abort and use the zvol `zfs send`
recipe from `ssd-tier-for-vm-storage.md` Phase 3.

### 2. Discard + SSD flag (Proxmox, outside OpenTofu's diff)

Disks here are `discard=ignore,ssd=0`. Re-read the new volume string from
`qm config 4323`, then:

```bash
qm set 4323 --scsi0 ssd_pool:vm-4323-disk-N,<existing opts>,discard=on,ssd=1
```

Takes effect on next VM start — schedule a reboot window (every DB client
reconnects; hermes/axon pgmcp servers recover on their own).

Guest side: btrfs with no `fstrim` today. Either add `services.fstrim.enable =
true;` to `hosts/database/configuration.nix` or mount with `discard=async` —
**separate follow-up change**, not part of the move.

### 3. Verify

- [ ] `qm config 4323` shows `ssd_pool:` on `scsi0`; `zfs list | grep 4323`
      shows nothing left on `zfs_pool`.
- [ ] Guest: `lsblk -d -o NAME,ROTA` → `sda 0` (after reboot with `ssd=1`).
- [ ] Postgres: `sudo systemctl status postgresql`, and from a client
      `psql "sslmode=verify-full host=database.homelab.local ..."` works.
- [ ] Write latency:
      `rate(node_disk_write_time_seconds_total{instance="homelab-database"}[5m]) / rate(node_disk_writes_completed_total{instance="homelab-database"}[5m])`
      should sit in low single-digit ms, and stay there during the next
      hofvarpnir download.
- [ ] Re-run the incident query during a download:
      `pg_stat_activity_count{datname="hofvarpnir",wait_event=~"WalSync|tuple"}`
      — no sustained queue.

## Not in scope

- No guest disk-path change: disko's `/dev/sda` and the scsi index are
  unchanged by the move. Disko only runs at install anyway.
- No `just deploy` — that is a nixos-anywhere reinstall and wipes the disk.
- jellyfin's media disk (`scsi1`, `vm-4344-disk-0`) stays on HDD, per the SSD
  tier plan.

## Related

- [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md) — parent plan.
- [`hofvarpnir-migration.md`](./hofvarpnir-migration.md)
- [`postgres-backup-pgbackrest.md`](./postgres-backup-pgbackrest.md)
