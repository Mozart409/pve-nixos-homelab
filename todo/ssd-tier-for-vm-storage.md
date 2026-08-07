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
| Size / alloc / free | 3.62 T / **948 G** / 2.70 T — `CAP 25 %`, `FRAG 25 %` *(2026-08-08: 1.08 T, `CAP 29 %`, `FRAG 27 %`)* |
| `zfs list` USED | **2.83 T** — the gap vs 948 G is `refreservation` (thick provisioning), not data |
| `logicalused` (pool root) | **1.00 T** |
| `ashift` | **12** — match on the new pool |
| `feature@allocation_classes` | `enabled` (a `special` vdev *would* be possible) |
| `feature@device_removal` | `enabled` (all-mirror pool → vdev removal supported) |
| Last scrub | Sun 2026-07-12, 14 h 09 m, **0 errors** |
| All zvols | `volblocksize=16K` — see the `special_small_blocks` trap below |
| SATA ports | **6 total, 3 used** (`sda` HDD, `sdb` Intenso SSD 476.9 G, `sdc` HDD) — **now 5 used**, see Build log |
| SATA controller | `01:00.1` AMD 500 Series Chipset |
| PCIe slots | **all 7 `Available`** — 1× x16, 4× x4, 1× x2, 1× x1. Nothing is plugged in. |
| Drives on hand | **2× Kingston SA400S37 960 GB SATA** (were earmarked for a Turing Pi 2.5) — **installed 2026-08-07**, serials `50026B73834B3A86` / `50026B73834B3315` |
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

## Status — pool built, immich on SSD (2026-08-08)

**Phases 0, 1 and 3 are done.** `ssd_pool` is live on 2× Kingston A400 960 GB
(888 G mirror), and immich's CT 104 rootfs now lives on it — 70.4 G moved in
**1 h 03 m** at ~21.4 MB/s, container verified healthy, source dataset
destroyed. `ssd_pool` sits at **70.4 G of 888 G (8 %)**.

**Phase 2** (the VM root disks — the whole point) has **not started**.
**Phase 4** (PBS cache) is still an open measurement.

See the [Build log](#build-log-2026-08-0708) below for the measured numbers —
including the one finding that changes the plan: **`pct move-volume` is a
file-level rsync, not a `zfs send`**, and is unusable on this pool.

Two things were done earlier, during the investigation:

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

## Build log (2026-08-07/08)

### Hardware install — power off, do not hot-plug

Both SSDs were installed with the host powered down. SATA hot-plug is a per-port
BIOS toggle that is off by default on this board, so a live insert would have
needed a reboot anyway — and the two `zfs_pool` HDDs share the same cable
bundle, where a bumped connector under power is a fault on the only copy of
everything.

Shutdown sequence that matters on this host: **stop VM 208 (Home Assistant)
first and confirm it is stopped.** A wedged ConBee leaves its kvm blocked in
uninterruptible I/O and the host shutdown hangs — IPMI is then the only way out
(see [[homeassistant-vm-conbee-passthrough]]).

**The BMC cannot be powered off from its own web UI.** It runs on the PSU's 5 V
standby rail, so it is alive whenever the machine is on mains. `Cold Reset` in
the BMC Action panel only reboots the BMC. To actually de-energise: graceful
`ACPI Shutdown` → wait for *"Host is currently off"* → PSU rocker to `O` →
unplug the C13 → hold the case power button ~5 s to drain. Use `Power Off` /
`Power Cycle` only as the escape hatch for a hung shutdown; they are an
immediate hard cut and dirty for ZFS.

### Enumeration shifted, exactly as predicted

Post-install `lsblk`:

| Device | Was | Is | What |
| --- | --- | --- | --- |
| `sda` | HDD | **KINGSTON SA400S37960G** `50026B73834B3A86` | new |
| `sdb` | Intenso 476.9 G | Intenso 476.9 G | boot, unchanged |
| `sdc` | HDD | **KINGSTON SA400S37960G** `50026B73834B3315` | new |
| `sdd` | — | HGST 3.6 T `PL2331LAGUT5JJ` | `zfs_pool` |
| `sde` | — | HGST 3.6 T `PL1331LAGSK2UH` | `zfs_pool` |

The HDDs moved from `sda`/`sdc` to `sdd`/`sde` and `zfs_pool` imported `ONLINE`
with 0 errors regardless, because it is built on `by-id`/`wwn`. This is the
[[disko-multidisk-by-id]] rule paying for itself on the PVE host.

### Phase 0.1 — SMART baseline

Both drives: `SMART overall-health self-assessment test result: PASSED`,
`Power_On_Hours 0`, `Reallocated_Event_Count 0`. Factory-fresh, never spun up.

The A400's attribute set is sparse — the usual wear-indicator greps match
nothing. Capture full `smartctl -A` output if you want a real zero-hour baseline
to diff against later.

### Phase 1 — pool built

Created exactly as specified in Phase 1.2/1.3. Verified state:

| Property | Value |
| --- | --- |
| `zpool status` | `mirror-0 ONLINE`, both Kingstons by-id, 0 errors |
| Size / free | **888 G** / 887 G (`pvesm`: ~860 GiB available) |
| `autotrim` | `on` |
| `ashift` | `12` (matches `zfs_pool`) |
| `compression` / `atime` / `xattr` | `lz4` / `off` / `sa` |
| `/etc/pve/storage.cfg` | `sparse 1` present ✓ |

**Doc fix for Phase 1.4:** `autotrim` is a **pool** property, not a dataset
property. `zfs get autotrim` errors out. The correct split is:

```bash
zpool get autotrim,ashift ssd_pool
zfs  get compression,atime,xattr ssd_pool
```

### `pct move-volume` is an rsync — do not use it for CT 104

**This is the finding that changes Phase 3.** `pct move-volume` on a container
**subvol** does a file-level copy, not a dataset send. Measured on CT 104's
70.4 G rootfs:

| Method | Throughput | Projected time |
| --- | --- | --- |
| `pct move-volume 104 rootfs ssd_pool --delete 1` | **2–4 MB/s** | **5–10 hours** |
| `zfs send \| zfs recv` | **~25 MB/s avg** (14–34 MB/s) | **~50 minutes** |

The rsync path showed 95–118 read IOPS at 1.4–3.5 MB/s — the pool's documented
~30 KB random-read signature, i.e. it was chasing individual files. A `zfs send`
walks block pointers in object order and reads far closer to sequentially.

**Aborting `pct move-volume` is safe.** Ctrl-C left the source dataset untouched
(`--delete` only fires after a successful copy) and PVE cleaned up the partial
target by itself — `ssd_pool` went straight back to 696 K used, nothing to
destroy by hand. The container config was also left pointing at `zfs_pool`.

Roughly a **10× speedup**, and it costs one hand-edit of `/etc/pve/lxc/104.conf`.
See the rewritten Phase 3.

### The A400s are not the bottleneck — the HDDs are

Measured during the `zfs send`, which is the question the Risks section asks:

| Pool | Reads | Writes | Read size |
| --- | --- | --- | --- |
| `ssd_pool` (write target) | — | **80–218 IOPS**, 6–23 MB/s | — |
| `zfs_pool` (read source) | **50–129 IOPS**, 0.4–7.3 MB/s | 107–145 IOPS (other guests) | **8–80 KB** |

80–218 write IOPS is nothing for a SATA SSD — thousands is normal. **If the SLC
cache had collapsed the SSDs would be pinned with the HDDs idle; the opposite is
true.** The HDD mirror sat at its random-read ceiling the whole time, and it was
simultaneously serving 107–145 write IOPS from the ~19 other guests — the send
only ever got a fraction of an already-inadequate IOPS budget.

**Nothing here argues for the NVMe fallback.** The A400s were never asked for
anything. Note also that this transfer is close to their worst case — one long
uninterrupted write with no idle time to fold SLC back into TLC — and normal
bursty VM workloads will behave better.

**`zpool iostat` accounting trap:** on a mirror, pool-level **write** bandwidth
is the sum across both leaves, i.e. **2× the logical write**. **Reads** are
load-balanced, so the pool figure *is* the logical read. Forgetting this makes
writes look inflated relative to reads.

### Drift since the 2026-07-28 survey

- `zfs_pool` is now **1.08 T alloc, `CAP 29 %`, `FRAG 27 %`** (was 948 G / 25 % /
  25 %). Still nowhere near a capacity problem.
  **`FRAG` is free-space fragmentation, not file fragmentation** — it describes
  the size distribution of free segments, i.e. how hard future allocations will
  be to place. It says nothing about existing data layout, there is no defrag
  for a copy-on-write filesystem, and 27 % at 29 % full is unremarkable. It
  should *improve* as Phase 2 frees whole zvols. Ignore this column.
- SATA ports: **5 of 6 used** (was 3 of 6). One spare left, as planned.

### Post-Phase-3 `zfs_pool` inventory (2026-08-08, by `refer`)

Re-measured after immich left. `refer` is real on-disk data, so this supersedes
the `logicalused` table at the top:

| Volume | `used` | `refer` | Destination |
| --- | --- | --- | --- |
| `vm-4344-disk-0` | 780 G | **566 G** | jellyfin media — **stays on HDD** |
| `vm-180-disk-0` | 520 G | **217 G** | PBS `r2-cache` — stays (Phase 4 decides) |
| 17× VM root disks | — | **~234 G** | **→ SSD (Phase 2)** |
| `vm-208-disk-1` | 112 G | 15.7 G | HA root — see below |
| `subvol-102-disk-0` | 1.33 G | 1.33 G | stays |

**Phase 2 target is ~250 G** (root disks incl. HA), landing `ssd_pool` at
**~320 G of 888 G (36 %)** rather than the 41 % this doc originally projected.

**The `refreservation` illusion, confirmed:** `zfs_pool` reports `used` **2.93 T**
against roughly **1.19 T** of actual `refer`. The doc named `vm-4334`, `vm-4345`
and `vm-4347` as the thick-provisioned offenders (260 G each holding 16–24 G);
add **`vm-4340`** (203 G / 11.6 G), **`vm-4348`** (102 G / 10.4 G) and
**`vm-208-disk-1`** (112 G / 15.7 G) to that list.

**Open question — does HA (VM 208) move?** Its root is only 15.7 G, but it is a
hand-created VM outside this repo with ConBee USB passthrough, and moving it
means a stop/start cycle on the guest most likely to wedge on shutdown
([[homeassistant-vm-conbee-passthrough]]). Passthrough is by vendor:product on
the same node, so it survives a disk move — but sequence it last, and do not
bundle it with a batch.

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

- [x] **0.1 DONE 2026-08-07** — both `PASSED`, `Power_On_Hours 0`,
      `Reallocated_Event_Count 0`. Factory-fresh. SMART-check both Kingstons
      before trusting them with anything:
      ```bash
      ls -l /dev/disk/by-id/ | grep -i kingston
      smartctl -a /dev/sdX | grep -Ei 'Power_On_Hours|Percent|Wear|Reallocated|Pending'
      ```
      Two drives from the same batch tend to wear together — note both.
- [x] **0.2 SKIPPED — no longer needed.** The dress rehearsal was only ever a
      way to test the theory without buying anything; `ssd_pool` now exists, so
      test on the real thing. (`/dev/sdb` is confirmed the Intenso boot drive
      carrying `local` + `local-lvm`; `pvesm status` shows `local-lvm` at
      5.6 % of 365 G, so there *is* room if a fallback is ever wanted.)
      Original step: identify `/dev/sdb` (Intenso SSD, 476.9 G). Almost certainly the
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
- [x] **0.5 DONE 2026-08-07** — both drives installed and enumerating. Power
      and mounting were not a problem. **Do this with the host powered off**, see
      the Build log for the shutdown sequence (VM 208 first) and why the BMC
      staying lit is expected rather than a fault.

## Phase 1 — build the pool ✅ DONE 2026-08-07

- [x] **1.1** Both drives installed, host powered off. Enumerated as `sda` and
      `sdc`; the HDDs shifted to `sdd`/`sde` (see Build log).
- [x] **1.2** Pool created. **`by-id` only**, never `/dev/sdX` — enumeration is
      not stable ([[disko-multidisk-by-id]]), and this install proved it by
      moving both HDDs two letters:
      ```bash
      zpool create -o ashift=12 -o autotrim=on \
        -O compression=lz4 -O atime=off -O xattr=sa \
        ssd_pool mirror \
        /dev/disk/by-id/ata-KINGSTON_SA400S37960G_50026B73834B3A86 \
        /dev/disk/by-id/ata-KINGSTON_SA400S37960G_50026B73834B3315
      ```
      No `-f` needed — the drives were blank.
- [x] **1.3** Registered with Proxmox, **thin provisioned**:
      ```bash
      pvesm add zfspool ssd_pool -pool ssd_pool -sparse 1 -content images,rootdir
      ```
      `sparse 1` confirmed present in `/etc/pve/storage.cfg`.
- [x] **1.4** Sanity-checked. **888 G**, ~860 GiB available via `pvesm`.
      Note `autotrim` is a **pool** property — `zfs get autotrim` is an error:
      ```bash
      zpool status ssd_pool
      zpool list -v ssd_pool
      zpool get autotrim,ashift ssd_pool        # autotrim=on, ashift=12
      zfs  get compression,atime,xattr ssd_pool # lz4, off, sa
      grep -A5 '^zfspool: ssd_pool' /etc/pve/storage.cfg
      ```

## Phase 2 — migrate the VM root disks (the whole ballgame)

~287 G across 18 zvols. `qm move-disk` runs **live**, one VM at a time.

- [ ] **2.1** Start with jellyfin and the two or three noisiest others, so the
      difference is measurable early. **jellyfin's mapping is confirmed
      (2026-08-07)** and the volume numbering is deliberately confusing — go by
      the **scsi key**, not the volume name:

      | Key | Volume | Size | Action |
      | --- | --- | --- | --- |
      | `scsi0` | `vm-4344-disk-1` | 32 G (OS root) | **move** |
      | `scsi1` | `vm-4344-disk-0` | 768 G declared (media) | **leave on HDD** |

      ```bash
      qm config 4344 | grep -E '^(scsi|virtio|sata|ide)[0-9]'
      qm move-disk 4344 scsi0 ssd_pool --delete 1
      ```
      Confirm the disk key (`scsi0`/`virtio0`/`sata0`) per VM first — `qm config <vmid>`.

      **Unverified: whether `qm move-disk` has the same rsync problem as
      `pct move-volume`.** VM disks are zvols, not subvols, so PVE should use a
      block-level copy rather than a file walk — but *measure the first one*.
      If it crawls at single-digit MB/s, fall back to the `zfs send` recipe in
      Phase 3 (adapted for zvols) rather than grinding through 18 disks.
- [ ] **2.2** Re-measure after the first few. If IO pressure has not visibly
      dropped for those guests, **stop and re-diagnose** before moving the rest.
- [ ] **2.3** Migrate the remaining VM root disks.
- [ ] **2.4** **Explicitly do not move** `vm-4344-disk-0` (437 G jellyfin media).
- [ ] **2.5** Expect the initial copy to be slow, but **not for the reason this
      doc originally assumed.** Measured during Phase 3: the A400 write side
      never exceeded 218 IOPS and was nowhere near saturated — the **HDD read
      side** is the constraint, at 50–129 IOPS with 8–80 KB reads, while also
      serving every other guest. Budget by the read source, not the SSDs.
      This is one-time.
- [ ] **2.6 After each move, enable discard and the SSD flag.** Disks here are
      configured `discard=ignore,ssd=0` — correct for spinning rust, wrong for
      flash. Without guest discard, freed blocks are never released back to the
      zvol, and the DRAM-less A400 controller degrades. Re-read `qm config
      <vmid>` for the exact new volume string, then:
      ```bash
      qm set 4344 --scsi0 ssd_pool:vm-4344-disk-1,aio=io_uring,backup=1,cache=none,discard=on,iothread=0,replicate=1,size=32G,ssd=1
      ```
      `ssd=1` also makes the guest see the disk as non-rotational. Takes effect
      on the next VM start.
- [ ] **2.7 No repo change is needed for jellyfin.** `modules/disko-jellyfin.nix`
      pins by `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0`. The move
      preserves the scsi index, so the guest-side path is unchanged and disko
      does not care which host pool backs it.

## Phase 3 — migrate immich's LXC volume ✅ DONE 2026-08-08

**Result: 81.3 G streamed in 1 h 03 m 19 s ≈ 21.4 MB/s.** Rates through the run
were 34 → 14 → 24 → 13 MB/s — bursty, region-dependent, never smooth. The
received dataset matched the source exactly (70.4 G used / 80.3 G logical /
70.4 G refer). immich came up clean and photos render. Source destroyed.

**Do not use `pct move-volume`** — it is a file-level rsync and projects to
5–10 hours on this pool. Use `zfs send | zfs recv` and repoint the container by
hand: ~50 minutes, and strictly safer because the source survives until you
delete it deliberately.

CT 104 as inventoried 2026-08-07 (relevant bits — full detail in
[`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md)):

| Fact | Value |
| --- | --- |
| rootfs | `zfs_pool:subvol-104-disk-1,size=512G` — **single volume, no separate mountpoint** |
| Actual usage | `used` 70.4 G / `logicalused` 80.2 G / `refer` 70.4 G |
| Container | `unprivileged: 1`, 4 cores, 6144 MB, `onboot: 1`, `192.168.2.104` |

Note `zfs send` without `-c` streams **uncompressed** records, so the transfer
totals closer to the 80.2 G logical figure than the 70.4 G on-disk one. `-c`
would have bought almost nothing here — a library of JPEGs does not compress.

- [x] **3.1** Stop CT 104: `pct shutdown 104` → `pct status 104` = `stopped`.
- [x] **3.2** Snapshot and stream. Container is stopped, so the snapshot is
      consistent. `-v` prints progress to stderr and passes through the pipe:
      ```bash
      zfs snapshot zfs_pool/subvol-104-disk-1@move
      time zfs send -v zfs_pool/subvol-104-disk-1@move | zfs recv ssd_pool/subvol-104-disk-1
      ```
      **Expect it to be bursty, not smooth.** One-second plateaus are receive-side
      txg commits — the A400s have no power-loss protection so those flushes are
      honored slowly. Judge on a ~1-minute average, never the instantaneous rate
      (the `-v` display granularity is 0.1 G, so short windows are noise).
      Observed: 34 MB/s early, a slow stretch at ~14 MB/s through a fragmented
      region, back to ~24 MB/s. **~25 MB/s overall.**
- [x] **3.3** Restore properties and repoint the container. **`refquota` came
      through as `none`** — `zfs send` without `-p` carries no properties, and
      PVE derives the volume's reported size from `refquota`, so this is not
      cosmetic. `mountpoint` was correct by inheritance. Commands:
      ```bash
      zfs list -o name,used,logicalused,refer ssd_pool/subvol-104-disk-1
      zfs get mountpoint,refquota ssd_pool/subvol-104-disk-1
      # expect refer ~70.4 G and mountpoint=/ssd_pool/subvol-104-disk-1 (inherited)
      zfs set refquota=512G ssd_pool/subvol-104-disk-1     # only if it came through as none

      sed -i 's|zfs_pool:subvol-104-disk-1|ssd_pool:subvol-104-disk-1|' /etc/pve/lxc/104.conf
      grep rootfs /etc/pve/lxc/104.conf                    # re-read it — confirm size=512G survived
      ```
      Hand-editing `/etc/pve/lxc/104.conf` bypasses PVE's own bookkeeping. It is
      a normal operation on a plain text config, but verify the line afterwards.
- [x] **3.4** Start and verify **before reclaiming anything**:
      ```bash
      zfs destroy ssd_pool/subvol-104-disk-1@move
      pct start 104 && pct status 104
      pct exec 104 -- systemctl list-units 'immich*' --no-pager
      ```
      Load the web UI and confirm photos and thumbnails render.
- [x] **3.5** Only once immich is confirmed healthy, reclaim the source:
      ```bash
      zfs destroy zfs_pool/subvol-104-disk-1@move
      zfs destroy zfs_pool/subvol-104-disk-1
      zpool list
      ```
- [ ] **3.6 Watch item: the rootfs is declared `size=512G` while holding 70.4 G.**
      Under `sparse 1` that is a quota, not a reservation, so it does not eat
      space — but immich has permission to grow to 512 G of an 888 G pool.
      Remember this before putting much else on `ssd_pool`.
- [ ] **3.7** Note the interaction with
      [`immich-lxc-to-nixos-vm.md`](./immich-lxc-to-nixos-vm.md): that migration
      replaces CT 104 with a VM entirely. Moving to SSD now is still worth it —
      it does not conflict, and the new VM's disk should simply be created on
      `ssd_pool` when the time comes. **It also materially de-risks that
      migration:** its Phase 3.3 budgets "expect many hours" for the 74 GiB
      library rsync *specifically because it reads off the HDD pool*. With the
      source on flash, that rsync stops being the multi-hour ordeal it is
      costed as.

After phases 2+3: ~~**~367 G of 890 G (41 %)**~~ → **re-measured 2026-08-08:
~320 G of 888 G (36 %)**. Comfortable headroom for growth and snapshots.

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

- ~~**The A400s are the weakest link.**~~ **Not so far — measured 2026-08-08
  during the Phase 3 transfer and downgraded.** No PLP means sync writes are
  honored slowly and DRAM-less means random-write IOPS degrade under sustained
  load, both still true in principle. But under a 70 G sustained sequential
  write — close to their worst case, with no idle time to fold SLC back into
  TLC — they never went above **218 write IOPS** and were never the constraint.
  The HDD read side was, the entire time. **Nothing observed yet argues for the
  NVMe fallback.** Re-open this if Phase 2 disappoints; the migration path is
  identical. Mirror still gives redundancy against death, not against slowness.
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
