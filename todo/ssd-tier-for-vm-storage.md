# SSD tier for VM storage: move the random I/O off `zfs_pool`

Build a mirrored SATA-SSD pool on `pve-gigabyte` and move every VM root disk (and
immich's LXC volume) onto it. `zfs_pool` keeps only bulk sequential data.

**The problem is IOPS, not capacity.** `zfs_pool` is a **single 2-HDD mirror**
serving the zvols of all ~20 guests. A mirror vdev has the random-read IOPS of
*one* disk: measured **~39 read IOPS and ~1.15 MB/s per disk, ~30 KB average
read** under load, 200–490 ms latencies. Aggregate guest demand is 500+ IOPS —
roughly **6× oversubscribed**. Baseline utilisation is 13–16 %; under any random
workload it pins at 95 %+ and *every guest stalls together*. That is the
"jellyfin is slow" report from 2026-07-28, and it was never about jellyfin.

The pool is **25 % full**. Adding spindles for space solves nothing. The fix is
to move the ~287 GB of actual random-I/O working set onto flash and leave the
HDDs doing the one thing they are good at — large sequential reads.

**Live facts (verified 2026-07-28/29):**

| Fact | Value |
| --- | --- |
| `zfs_pool` layout | **single `mirror-0`**: `ata-HGST_HMS5C4040BLE640_PL1331LAGSK2UH` + `wwn-0x5000cca22ecbb80a` |
| Size / alloc / free | 3.62 T / **948 G** / 2.70 T — `CAP 25 %`, `FRAG 25 %` |
| `zfs list` USED | **2.83 T** — the gap vs 948 G is `refreservation` (thick provisioning), not data |
| `logicalused` (pool root) | **1.00 T** |
| `ashift` | **12** — match on the new pool |
| `feature@allocation_classes` | `enabled` (a `special` vdev *would* be possible) |
| `feature@device_removal` | `enabled` (all-mirror pool → vdev removal supported) |
| Last scrub | Sun 2026-07-12, 14 h 09 m, **0 errors** |
| All zvols | `volblocksize=16K` — see the `special_small_blocks` trap below |
| SATA ports | **6 total, 3 used** (`sda` HDD, `sdb` Intenso SSD 476.9 G, `sdc` HDD) |
| SATA controller | `01:00.1` AMD 500 Series Chipset |
| PCIe slots | **all 7 `Available`** — 1× x16, 4× x4, 1× x2, 1× x1. Nothing is plugged in. |
| Drives on hand | **2× Kingston SA400S37 960 GB SATA** (were earmarked for a Turing Pi 2.5) |
| Also on the shelf | 2× HGST 4 TB HDD — **deliberately not being installed**, see Decisions |

### Where the 1.00 T of logical data actually lives

| Volume | logical | What it is | Destination |
| --- | --- | --- | --- |
| `vm-4344-disk-0` | 437 G | jellyfin **media** | stays on HDD |
| `vm-180-disk-0` | 222 G | PBS **`r2-cache`** | stays on HDD (phase 4 decides) |
| `subvol-104-disk-1` | 80 G | immich LXC | → SSD (phase 3) |
| **18× VM root disks** | **~287 G** | every guest's OS disk | **→ SSD (phase 2)** |
| `subvol-102-disk-0` | 1.9 G | — | stays |

The entire random-I/O working set is **under 300 GB**. The two volumes that make
the pool look full are sequential bulk that belongs on spinning rust.

**Provisioning is the other half of the illusion:** three zvols (`vm-4334`,
`vm-4345`, `vm-4347`) are provisioned at 260 G each while holding 10–22 G.
Proxmox reserves the full declared size, so it sees 2.83 T of 3.62 T committed
(78 %) against 948 G of real data. Thin provisioning on the new pool fixes this
for free — and is **mandatory**, since 1.53 T of reservations will not fit in
890 G of SSD.

## Status — not started (2026-07-29)

Investigation complete, hardware identified, nothing built. Two things were
already done during the investigation:

- ✅ `zfs_arc_max` raised **3 GiB → 8 GiB** (live + `/etc/modprobe.d/zfs.conf` +
  `update-initramfs -u -k all`). Host boots plain GRUB; `proxmox-boot-tool` is
  not configured. **Outside this repo and OpenTofu** — `iac-apply` cannot wipe it.
- ❌ ~~PBS services restarted — it was running **4.1.1 with 4.2.3-1 installed**
  (never restarted after an `apt` upgrade).~~ **This was a misreading. Corrected
  2026-08-01.** `proxmox-backup-manager version` prints
  `<package> <AVAILABLE version> running version: <RUNNING version>` — so
  "`4.2.4-1 running version: 4.1.1`" never meant a newer package was sitting
  installed-but-not-loaded. Verified on the host:

  | Check | Result |
  | --- | --- |
  | `dpkg -l \| grep proxmox-backup-server` | `4.1.1-1` |
  | `apt policy proxmox-backup-server` | **Installed `4.1.1-1`, Candidate `4.2.4-1`** |
  | Last dpkg upgrade | **2026-01-12**, 4.0.14-1 → 4.1.1-1 |
  | Both daemons' start time | 2026-07-29 12:43:23 CEST (clean, simultaneous) |

  Installed and running agree at 4.1.1. **The restart fixed a problem that did
  not exist.** The real finding is different and larger: **PBS has not been
  upgraded since January 2026** and is four releases behind (4.2.1 → 4.2.4).
  Tracked in [`pbs-verify-failures.md`](./pbs-verify-failures.md) — the S3
  datastore backend is a young feature and this store has been running
  seven-month-old code against it the entire time.

Also already mitigated, separately: the immich backup moved from daily to
`sun 01:00`, which took the 8-hour pool saturation from every night to once a
week. See [`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md).

---

## Decisions (locked)

- **Use the 2× Kingston A400 960 GB.** They are budget DRAM-less TLC with no
  power-loss protection and a sustained-write cliff once the SLC cache fills
  (~100 MB/s after the first several GB). None of that matters: the bar is
  **78 IOPS**. Even a mediocre SATA SSD clears it by two orders of magnitude.
  300 TBW endurance vs a few GB/day of writes is a non-issue.
  - Cost of the decision: the Turing Pi 2.5 build needs its own drives.
  - Reversible: a ZFS mirror can be upgraded drive-by-drive with no downtime if
    the A400s ever prove limiting.
- **Separate pool (`ssd_pool`), not a `special` vdev on `zfs_pool`.** A `special`
  vdev becomes structurally part of the pool — lose it and `zfs_pool` is gone,
  photos included. A separate pool fails in isolation, and PBS has backups of
  everything that would be on it.
  - **The `special_small_blocks` trap, for the record:** every zvol here is
    `volblocksize=16K`. Setting `special_small_blocks=32K` pool-wide would route
    *100 % of VM data* to the special vdev — 948 G into whatever was bought,
    silently spilling back to HDD on fill. It would have had to be set
    per-dataset (`0` on zvols, `32K` on `subvol-104`). Avoided entirely by not
    going down this path.
- **Do not install the 2 spare HGST 4 TB drives.** Port math: 6 SATA ports,
  3 used. The two SSDs take it to 5. Adding the HDDs too would need 7.
  - They would buy ~156 IOPS instead of 78 — 2× on a 6× oversubscription. The
    100× lever is flash. Capacity is not a constraint at 25 % full.
  - If they are ever wanted: a used LSI 9211-8i in IT mode (~€30) adds 8 ports,
    and every PCIe slot is free.
- **Thin provisioning (`-sparse 1`) on the new storage.** Non-negotiable, see above.
- **`ashift=12`** to match `zfs_pool`, **`autotrim=on`** — DRAM-less controllers
  degrade noticeably without TRIM.
- **Bulk stays on HDD:** jellyfin's 437 G media and (initially) PBS's `r2-cache`.

### Rejected

- **NVMe on PCIe adapters.** Genuinely the better buy — every PCIe slot is free,
  two x4 slots take single-M.2 adapters (~€8 each, no bifurcation), and ~€190 of
  new 1 TB NVMe beats used SATA on warranty and ~10× the IOPS. Rejected only
  because the Kingstons are already owned and the pool hurts now. **Revisit if
  the A400s disappoint** — the migration path is identical.
- **2× used Verbatim Vi550 1 TB @ €95 ea.** Superseded by the drives on hand.
- **PBS garbage collection as a concern.** Investigated and **cleared**: the
  `r2-store` datastore is `backend type=s3` (Cloudflare R2, bucket `pve-backups`),
  so GC reconciles bucket listings against local index files rather than walking
  a local chunk store touching atime on millions of files. Last run
  **1 m 47 s**, removed 25.95 GiB, `OK`. Weekly `sat 05:15`, off-peak. Leave it.

---

## Phase 0 — pre-flight

- [ ] **0.1** SMART-check both Kingstons before trusting them with anything:
      ```bash
      ls -l /dev/disk/by-id/ | grep -i kingston
      smartctl -a /dev/sdX | grep -Ei 'Power_On_Hours|Percent|Wear|Reallocated|Pending'
      ```
      Two drives from the same batch tend to wear together — note both.
- [ ] **0.2** Identify `/dev/sdb` (Intenso SSD, 476.9 G). Almost certainly the
      boot drive with `local-lvm`. If a few hundred GB are free it is a **zero-cost
      dress rehearsal** — move 3–4 busy VM disks there first and confirm the theory
      before touching anything else.
      ```bash
      lsblk -f /dev/sdb; df -h /; lvs; cat /etc/pve/storage.cfg
      ```
- [ ] **0.3** Find where the backup job is defined. `/etc/pve/jobs.cfg` **does not
      exist** on this host, yet a `sun 01:00` schedule is active.
      ```bash
      cat /etc/pve/vzdump.cron 2>/dev/null; ls /etc/pve/
      ```
- [ ] **0.4** Capture a "before" baseline while the pool is busy, to compare against
      later — `rate(node_pressure_io_waiting_seconds_total{instance="homelab-*"}[15m])`
      and `rate(node_disk_io_time_seconds_total{instance="pve-gigabyte",device=~"sda|sdc"}[10m])`.
- [ ] **0.5** Physical: 2 free SATA data ports confirmed, but check the PSU has
      2 spare SATA power leads and there is somewhere to mount 2.5" drives. SSDs
      draw ~2 W, so a splitter is fine.

## Phase 1 — build the pool

- [ ] **1.1** Install both drives (ports 4 and 5, leaving one spare).
- [ ] **1.2** Create the pool. **`by-id` only**, never `/dev/sdX` — enumeration is
      not stable ([[disko-multidisk-by-id]]):
      ```bash
      zpool create -o ashift=12 -o autotrim=on \
        -O compression=lz4 -O atime=off -O xattr=sa \
        ssd_pool mirror \
        /dev/disk/by-id/ata-KINGSTON_SA400S37960G_<serial-A> \
        /dev/disk/by-id/ata-KINGSTON_SA400S37960G_<serial-B>
      ```
- [ ] **1.3** Register with Proxmox, **thin provisioned**:
      ```bash
      pvesm add zfspool ssd_pool -pool ssd_pool -sparse 1 -content images,rootdir
      ```
- [ ] **1.4** Sanity-check: `zpool status ssd_pool`, `zpool list -v ssd_pool`,
      `zfs get autotrim,compression,atime ssd_pool`. Expect ~890 G usable.

## Phase 2 — migrate the VM root disks (the whole ballgame)

~287 G across 18 zvols. `qm move-disk` runs **live**, one VM at a time.

- [ ] **2.1** Start with jellyfin (`vm-4344-disk-1`, 32.5 G) and the two or three
      noisiest others, so the difference is measurable early.
      ```bash
      qm move-disk <vmid> scsi0 ssd_pool --delete 1
      ```
      Confirm the disk key (`scsi0`/`virtio0`/`sata0`) per VM first — `qm config <vmid>`.
- [ ] **2.2** Re-measure after the first few. If IO pressure has not visibly
      dropped for those guests, **stop and re-diagnose** before moving the rest.
- [ ] **2.3** Migrate the remaining VM root disks.
- [ ] **2.4** **Explicitly do not move** `vm-4344-disk-0` (437 G jellyfin media).
- [ ] **2.5** Expect the initial copy to be slow — the A400's SLC cache exhausts
      after several GB and settles near ~100 MB/s. Budget an hour or so total.
      This is one-time.

## Phase 3 — migrate immich's LXC volume

- [ ] **3.1** Stop CT 104.
- [ ] **3.2** `pct move-volume 104 rootfs ssd_pool --delete 1` (~80 G).
- [ ] **3.3** Start CT 104, verify immich is healthy.
- [ ] **3.4** Note the interaction with
      [`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md): that migration
      replaces CT 104 with a VM entirely. Moving to SSD now is still worth it —
      it does not conflict, and the new VM's disk should simply be created on
      `ssd_pool` when the time comes.

After phases 2+3: **~367 G of 890 G (41 %)**. Comfortable headroom for growth
and snapshots.

## Phase 4 — decide on PBS's cache (measure first)

`vm-180-disk-0` is PBS's `/mnt/datastore/r2-cache`, 222 G logical, on the same
mirror as everything it backs up. During a backup that mirror serves three
streams at once: read source → write chunk to cache → read chunk back to PUT to
R2. **The backup competes with itself.**

- [ ] **4.1** Settle **disk-bound vs R2-bound** — this decides whether moving the
      cache shortens the backup window at all. With the pool quiet:
      ```bash
      rclone copy /path/to/1G-testfile r2:pve-backups/throughput-test -P
      ```
      Evidence so far points to **disk-bound**: the chunk log showed ~one 1.5 MB
      PUT every 2 s (~0.75 MB/s), far below what R2 does over a normal uplink,
      while the pool sat at 95 %+ with 200–490 ms latencies. If the idle test
      sustains tens of MB/s, that gap was the disks.
- [ ] **4.2** Check what the 222 G actually consists of. Cache is evictable;
      indexes, manifests and catalogs are not, and they are small. PBS may only
      need 60–100 G of genuinely hot space.
      ```bash
      proxmox-backup-manager datastore show r2-store
      du -sh /mnt/datastore/r2-cache; du -sh /mnt/datastore/r2-cache/* | sort -h | tail
      ```
- [ ] **4.3** Confirm the cache is **bounded**. If PBS keeps growing it with a
      long prune policy rather than evicting, it will outgrow `ssd_pool` and
      wants a different answer.
- [ ] **4.4** Only then decide. Moving it takes two of three streams off the HDDs,
      but it only matters a few hours on Sunday, and it pushes `ssd_pool` toward
      66 % full. **Measure a Sunday backup post-phase-2 before committing.**

## Phase 5 — cleanup

- [ ] **5.1** Re-check `zpool list zfs_pool` — allocation should drop by ~287 G
      plus the released reservations.
- [ ] **5.2** Consider enabling thin provisioning on the `zfs_pool` storage too,
      to reclaim the phantom 1.5 T of reservations on what remains.
- [ ] **5.3** Scrub both pools.
- [ ] **5.4** Update [[pve-storage-hdd-bottleneck]] — the memory currently says
      the 2-HDD mirror is under *every* VM, which stops being true after phase 2.

---

## Verification

- **The real test:** `rate(node_pressure_io_waiting_seconds_total{instance="homelab-*"}[15m])`
  no longer spikes across many hosts simultaneously. That simultaneity was the
  signature of the shared-pool bottleneck.
- `rate(node_disk_io_time_seconds_total{instance="pve-gigabyte",device=~"sda|sdc"}[10m])`
  stops pinning at 95 %+ during normal operation.
- Guest-side read latency drops from 200–490 ms to single-digit ms.
- Run a Sunday backup and compare its duration against the 8 h+ baseline.
- `zpool status ssd_pool` clean after a scrub; `smartctl` wear indicators stable.

## Risks

- **The A400s are the weakest link.** No PLP means sync writes are honored
  slowly; DRAM-less means random-write IOPS degrade under sustained load. Mirror
  gives redundancy against death, not against slowness. If phase 2 disappoints,
  the answer is NVMe — not more HDDs.
- **Both drives are the same model, likely the same batch.** Correlated wear.
  Scrub regularly and watch SMART; do not treat the mirror as a backup.
- **`qm move-disk --delete 1` removes the source.** It is live and safe, but
  there is no undo once it completes. Confirm PBS has a current backup of any
  VM before moving it.
- **Do not confuse this with capacity work.** The pool is 25 % full. Anyone
  reading `zfs list` and seeing 2.83 T of 3.62 T will reach for more spindles;
  that is the `refreservation` illusion and it is the wrong fix.
- **One SATA port left after this.** Any further SATA expansion needs an HBA.

## Related

- [`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md) — the other half of
  the same storage problem. LXC pxar backups are what saturate the pool; that
  migration removes the cause, this one removes the contention.
- [[pve-storage-hdd-bottleneck]] — the standing diagnosis and PromQL.
