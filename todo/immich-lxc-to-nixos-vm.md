# immich migration: old LXC (CT 104) → NixOS VM

Move immich off the legacy hand-managed LXC (`CT 104`, comment `immich`) onto a
NixOS VM managed by this repo. CT 104 is one of the last hosts not on NixOS.

**Primary driver is the backup, not the app.** PVE backs containers up with a
**pxar filesystem walk** — every photo, thumbnail, and ML derivative is read as a
separate file, *every night*, because containers have no dirty-block tracking.
A VM is backed up **block-level with QEMU dirty bitmaps**, so an incremental run
reads only changed blocks.

The pool cannot serve that walk. Measured on `pve-gigabyte` 2026-07-28 while the
backup ran: **~39 read IOPS and ~1.15 MB/s per disk, ~30 KB average read** — a
2-HDD mirror doing pure random I/O. At that rate a full read of the 74 GiB
library is **~18 hours**. The 2026-07-28 run started 01:38 UTC and was still
going 8 h later.

For contrast, on the same pool the same night:

| Guest | Type | Method | Duration |
| --- | --- | --- | --- |
| `ct/102` | container | pxar, file-level | 4 min |
| `vm/4323` | VM | block-level | 16 min |
| `vm/4327` | VM | block-level | 18 min |
| **`ct/104` (immich)** | **container** | **pxar, file-level** | **8 h+, unfinished** |

This gets strictly worse as the library grows, and it is what saturates the pool
into the morning — see the related storage work below.

### Re-measured 2026-08-01 (PBS task times, `03:00` job)

The gap widened once the VMs had warm dirty bitmaps, and the run picked up a
**fourth** VM (`vm/4341`, forgejo) whose first-ever backup gives us the number
this document was previously only estimating.

| Guest | Type | Method | Duration |
| --- | --- | --- | --- |
| `ct/102` | container | pxar, file-level | 7 min |
| `vm/4323` | VM | block-level, **incremental** | **7 min** |
| `vm/4327` | VM | block-level, **incremental** | **7 min** |
| `vm/4341` | VM | block-level, **first-ever full** | **16 min** |
| **`ct/104` (immich)** | **container** | **pxar, file-level** | **8 h 32 m** (2026-07-28, `OK`) |

Two things this settles:

- **The Jul 28 run did finish** — 01:38 → 10:11 UTC, status `OK`, 8 h 32 m. The
  "unfinished" note above was written while it was still running. So 8.5 h is
  the *completion* time for a 74 GiB library, not a floor.
- **`vm/4341` is the cold-cache datapoint.** A 40 GiB disk, no dirty bitmap, full
  block read: **16 minutes**. See the revised dirty-bitmap risk below.

**Live facts (verified 2026-07-28):**

| Fact | Value |
| --- | --- |
| Last complete snapshot | **2026-08-08: two in the datastore** (`keep-last=2`). **2026-08-02 01:00 CEST** — 82.0 GB `root.pxar`, 42.0 MB catalog, **no verification record at all**. **2026-07-28 03:38 CEST** — 79.4 GB, 29.7 MB catalog, verification **`ok`** (the single-threaded re-verify from 08-01). So the *verified* net is the older one; the *current* one is unverified. |
| Library growth rate | **+2.6 GB of pxar and +41 % catalog size in the 5 days** between those two snapshots — the file count is climbing faster than the bytes |
| `root.pxar.didx` | **79,395,864,927 B ≈ 74 GiB** (OS + library) |
| `catalog.pcat1.didx` | 29.7 MB — a very large catalog, i.e. a very high file count |
| Backup target | `pbs-r2` datastore (`r2-store`), selection `104` |
| Backup schedule | **`sun 01:00`**, retention **keep-last=2** — moved off daily 2026-07-28 to stop the daily morning stall. An ~8.5 h run starting Sunday 01:00 saturates the pool until mid-morning Sunday. First run on the new schedule is **2026-08-02 01:00**. |
| Verification state | **Clean — the earlier `failed` flag was a false alarm.** Re-verified 2026-08-01 at `--read-threads 1`: **0 errors** across all 74 GiB. The weekly job's `read-threads=16` was manufacturing phantom chunk errors on an S3 backend. See [`pbs-verify-failures.md`](./pbs-verify-failures.md). |
| immich on CT 104 | **3.0.3** — upgraded in place 2026-07-29 (was 2.7.5). **Same version as nixpkgs → the cutover is no longer a version jump.** |
| Pool read ceiling | ~1.15 MB/s @ ~39 IOPS, ~30 KB avg read |
| immich in pinned nixpkgs | **3.0.3** (`services.immich` available) — verified `nix eval` 2026-07-29 |
| vectorchord in pinned nixpkgs | **1.1.1** (`postgresql18Packages.vectorchord`) |
| default `services.postgresql` package | **18.4** — what the immich VM gets unless pinned |
| Central Postgres (`homelab-database`) | `pkgs.postgresql_18` |
| Next free LAN IP | ~~`192.168.2.185`~~ → **`192.168.2.186`**. **Corrected 2026-08-08: `.185` is taken** by `scratchpad_vm` (`vm_id 4347`) — `iac/main.tf` and an A/PTR pair in `hosts/dns/configuration.nix`. Provisioning immich there would collide. |
| Next free `vm_id` | ~~`4348`~~ → **`4349`**. **Corrected 2026-08-08: `4348` is taken** by `woodpecker_vm` (`iac/main.tf:1084`). In-use guest IDs are 4323, 4325–4328, 4333–4341, 4344–4348. |
| immich refs in this repo | **none** — greenfield host |

## Status

**Not started** in this repo — planning only, no host/IaC/DNS changes yet.

**2026-07-29: the blocking prerequisite is done.** CT 104 was upgraded in place
**2.7.5 → 3.0.3**, which is exactly the "upgrade first, move second" sequencing
the Risks section recommended. Source and target now run the *same* immich
version, so the cutover is a same-version dump/restore + file copy rather than a
forward-only schema migration across a major release. The pgvecto.rs →
VectorChord extension swap was performed by immich's own 3.x upgrade path on the
LXC, not by us at cutover time — the highest-risk item in this plan is retired.

Reported on the LXC after the upgrade: immich 3.0.3, ExifTool 13.59, Node
v24.13.0, libvips 8.18.4, ImageMagick 7.1.2-21, FFmpeg 7.1.3-Jellyfin. Those are
the LXC image's bundled dependencies; the nixpkgs build pins its own and minor
differences there are expected and harmless — only the **immich version, the
Postgres major, and the vchord version** need to line up.

What is now left is ordinary work: provision the VM (Phase 1), stand up a clean
immich (Phase 2), move the data (Phase 3), cut over (Phase 4).

**2026-08-08: CT 104's volume moved to `ssd_pool`, and two facts here were
wrong.** The SSD tier landed ([`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md)
Phases 0–1 complete), and immich's rootfs was migrated off the HDD mirror. Three
things follow for this plan:

- **Both "next free" values in the fact table were stale.** `192.168.2.185` is
  scratchpad's and `vm_id 4348` is woodpecker's. Use **`.186`** and **`4349`**.
  Re-derive both at provisioning time rather than trusting this table — the
  homelab gained three guests between this doc being written and being read.
- **Phase 3.3 gets much cheaper.** The "expect many hours" rsync estimate was
  driven entirely by reading 74 GiB of small files off a ~78-IOPS HDD mirror.
  The source now lives on flash. Re-estimate rather than budgeting a night.
- **Phase 1.1 should target `ssd_pool`, not `zfs_pool`.**

Also inventoried while migrating (partial credit on Phase 0.2): CT 104 is
`unprivileged: 1`, 4 cores, 6144 MB RAM, `onboot: 1`, `192.168.2.104`, and
**everything lives on a single rootfs** (`subvol-104-disk-1`, declared
`size=512G`, actually using 70.4 G / 80.2 G logical) — there is **no separate
mountpoint** for the library. Still to capture: `mediaLocation`, Postgres
version and DB name, the immich uid/gid, and whether Redis is local.

**2026-08-01: re-measured against live PBS data.** The case is stronger than
when this was written — see the re-measured table above. `vm/4341`'s first-ever
backup supplies the cold-cache number the Risks section was estimating, and it
retires the dirty-bitmap caveat outright. A verification scare the same day —
the `ct/104` snapshot appearing corrupt — was **chased down and dismissed**: the
weekly verify job runs `read-threads=16` against the S3 backend and fabricates
chunk errors. Re-verified single-threaded, 0 errors. Immich's backup is intact
and the migration's fallback position holds. Still not started.

---

## Decisions

### Locked

- **VM, not LXC.** This is the entire point: block-level backup with dirty
  bitmaps. An LXC on NixOS would keep the pxar problem.
- **Postgres runs LOCALLY on the immich host** — a deliberate deviation from the
  central-DB convention (forgejo / romm / buildbot / hofvarpnir all use
  `homelab-database`). Immich 3.x requires the `vectorchord` extension **and**
  `shared_preload_libraries = ["vchord.so"]`
  (`nixos/modules/services/web-apps/immich.nix`). `shared_preload_libraries` is
  **cluster-wide** and needs a full Postgres restart, so adopting it on
  `homelab-database` would impose immich's requirements on every other database
  in the homelab. Keep the blast radius on the immich host: leave
  `services.immich.database.createDB = true` (the default), which provisions the
  DB, role, and both extensions locally.
- **Single disk.** Matches the current LXC and keeps the standard deploy flow.
  A second disk would force `nixos-anywhere .#immich` with a custom disko module
  (the jellyfin trap in `AGENTS.md` §6) for no benefit here.
- **`services.immich` from nixpkgs (3.0.3)**, not an OCI container. There is a
  first-class NixOS module; use it.

### Open

- **Disk size.** Library is ~74 GiB today. Size for growth — 250 GB is a
  reasonable starting point, and growing a virtual disk later is easy while
  repartitioning is not. Note this is thin-provisioned on `zfs_pool`, which has
  ~180 GB free on the r2-cache side; check pool free space before committing.
- **Machine learning.** `services.immich.machine-learning.enable` — the ML
  service is CPU-hungry and the host is already IO-starved. Consider leaving it
  off for the initial cutover and enabling it once storage is fixed.
- **Hostname.** `immich.homelab.local` (step-ca) is required. Decide whether a
  `homelab-immich.dropbear-butterfly.ts.net` tailnet vhost is also wanted —
  jellyfin has both, hofvarpnir is LAN-only.

---

## Phase 0 — Prerequisites (do before anything else)

- [x] **0.1 The 2.7.5 → 3.0.3 major upgrade — DONE 2026-07-29, in place on CT
  104.** This was the single blocking risk and it is now behind us. immich
  performed its own pgvecto.rs → VectorChord migration during the upgrade, on
  the source, where it is revertible from a PBS snapshot — instead of at cutover
  time on a half-migrated new host. Source and target are now both 3.0.3, so
  Phase 3 is a **same-version** dump/restore.

- [ ] **0.1a Record the source DB's extension and version state** — cheap, and
  it determines whether Phase 3.5 needs a manual reindex. On CT 104, in the
  immich database:

  ```sql
  \dx                                    -- expect vchord + vector, NOT vectors/pgvecto.rs
  SELECT extname, extversion FROM pg_extension ORDER BY extname;
  SHOW server_version;
  SHOW shared_preload_libraries;         -- expect vchord.so
  ```

  - [ ] Confirm `vchord` is present and `vectors` (pgvecto.rs) is **gone**. If
        `vectors` is still installed, the 3.x upgrade left a half-migrated DB —
        stop and finish the extension migration on the LXC before copying
        anything.
  - [ ] Note the **`vchord` version**. nixpkgs ships **1.1.1**. If the LXC's is
        older, the restored `face_index` / `clip_index` must be rebuilt on the
        VM — see Phase 3.5. The module's automatic reindex only fires when it
        observes the version *change between two runs on the same cluster*, so
        it will **not** trigger on a fresh restore.

- [ ] **0.1b Confirm the Postgres major version on CT 104.** nixpkgs' default
  `services.postgresql` is **18.4**; immich's container images have historically
  shipped 14/16/17, so a cross-major restore is likely. This is routine but
  changes the plan: dump with the **target's** `pg_dump` (18.x) against the
  source server, or pin `services.postgresql.package` on the VM to the source
  major. Decide which before Phase 2.1 — the pin is a one-line config change now
  and a rebuild-and-reload later.

- [ ] **0.1c Rehearse the restore** on a throwaway VM (or on the immich VM
  before real data lands). Much lower stakes than it was pre-upgrade — you are
  validating a dump/restore across Postgres majors, not an app migration.
- [ ] **0.2 Inventory the LXC.** Record `mediaLocation` (upload path), the
  Postgres version and DB name, the immich uid/gid, any non-default env vars,
  and whether Redis is local. `pct config 104` on the PVE host plus the
  compose/env files inside the container.
- [ ] **0.3 Confirm the library really is ~74 GiB** and how it splits between
  originals and regenerable derivatives (thumbs, encoded video, ML cache). Only
  originals are irreplaceable; the rest can be regenerated after cutover, which
  may let you move much less data.
- [ ] **0.4 Check `zfs_pool` free space** on `pve-gigabyte` — during cutover the
  old LXC and the new VM hold the library **simultaneously**.

## Phase 1 — Provision the VM

- [ ] **1.1 `iac/main.tf`** — add `immich_vm`: `vm_id = 4349`, `node_name =
  "pve-gigabyte"`, 4 cores (`type = "host"`), memory `dedicated = 8192`.
  **Set `floating = 0` / omit ballooning** — see the jellyfin balloon incident
  (2026-07-28: host memory pressure squeezed jellyfin 3.83 GiB → 1.85 GiB
  mid-workload). Single `scsi0` disk on **`ssd_pool`** (changed 2026-08-08 — the
  SSD tier now exists; do not put this on `zfs_pool`), 250 GB. Add to outputs.
  Budget check: `ssd_pool` is 888 G and CT 104's ~70 G already lives there.
- [ ] **1.2 `tofu apply`** in `iac/`.
- [ ] **1.3 `hosts/immich/configuration.nix`** — import `common.nix`,
  `tailscale.nix`, `step-ca-trust.nix`. Static IP `192.168.2.186/24`, gateway
  `192.168.2.1`. Node exporter with `["systemd" "processes"]`. Firewall: 22, 443,
  9100, `trustedInterfaces = ["tailscale0"]`.
- [ ] **1.4 `flake.nix`** — add to `hostAddrs`, `nixosConfigurations` (`mkHost`),
  and `colmenaHive`.
- [ ] **1.5 `hosts/dns/configuration.nix`** — A + PTR records for
  `immich.homelab.local` → `192.168.2.186`.
- [ ] **1.6 `hosts/otel/configuration.nix`** — Prometheus scrape job
  `immich-node`, target `immich.homelab.local:9100`, label
  `instance = "homelab-immich"`. (Address by DNS name, not raw IP — `AGENTS.md`
  §5 step 5.)
- [ ] **1.7** `git add` the new files, then `just fmt` and
  `nix eval ".#nixosConfigurations.immich.config.system.build.toplevel.drvPath"`.
- [ ] **1.8 Deploy.** Single disk → the standard flow applies:
  `just deploy-minimal <dhcp-ip>` → reboot onto the static IP →
  `just colmena-apply-host immich`. **Not** the jellyfin multi-disk path.
- [ ] **1.9** New host key → add to `secrets/secrets.nix` and `just reencrypt`
  (every host needs `tailscale-auth-key.age`). See `AGENTS.md` §6.

## Phase 2 — Immich config (app not yet holding data)

- [ ] **2.1 Enable `services.immich`** — `enable`, `host`/`port`,
  `mediaLocation`, `database.createDB = true` (local Postgres + pgvector +
  vectorchord), Redis. Decide `machine-learning.enable` per the open question.
  Set `services.postgresql.package` per the 0.1b decision (default is 18.4).
  The module already does the rest: it adds `pgvector` + `vectorchord` to
  `extensions`, sets `shared_preload_libraries = ["vchord.so"]` and
  `search_path = "\"$user\", public, vectors"`, and runs a
  `postgresql-setup` `ExecStartPost` that `CREATE EXTENSION IF NOT EXISTS`es
  all seven (`unaccent`, `uuid-ossp`, `cube`, `earthdistance`, `pg_trgm`,
  `vector`, `vchord`) and `ALTER EXTENSION … UPDATE`s them. Do not hand-roll
  any of that.
- [ ] **2.2 Caddy vhost** `immich.homelab.local` with the step-ca ACME directory,
  `reverse_proxy` to the immich port. Copy the jellyfin pattern. Set generous
  body-size limits — immich uploads are large.
- [ ] **2.3** Deploy and confirm a **clean, empty** immich starts, the DB is
  created with both extensions, and the web UI loads over `https://`. Do not
  touch real data until this is green.
- [ ] **2.4** If SSO is wanted, register the Pocket ID callback for **every**
  origin you will use — see the Open WebUI 0.9.6 lesson in `AGENTS.md` §6.

## Phase 3 — Data cutover (the risky part)

- [ ] **3.1 Stop immich on the LXC** and leave it stopped. All later steps assume
  a frozen source. (The hofvarpnir migration was easy precisely because the
  source was stopped throughout.)
- [ ] **3.2 `pg_dump`** the immich database on the LXC. Copy the dump off before
  touching anything else. Per 0.1b, if the majors differ, run the dump with the
  **newer** `pg_dump` (from the VM, over the network) — an older `pg_dump`
  cannot produce a reliable dump for a newer server, but the reverse is fine.
- [ ] **3.3 rsync the library** to the new VM's `mediaLocation`. ~~74 GiB off an
  HDD pool of small files — **expect many hours**, same physics as the backup.~~
  **Re-estimate (2026-08-08): the source is on `ssd_pool` now**, so the read side
  is no longer the ~78-IOPS mirror and this should be far quicker. Still run it
  in `tmux`/`screen` with `rsync -aHAX --info=progress2` and be ready to resume —
  but do not budget a night for it. Measure the first few minutes and extrapolate.
  If both source and target end up on `ssd_pool`, consider whether a `zfs send`
  of the dataset beats a file-level rsync here too (it did by ~10× for the LXC
  move — see [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md)),
  though rsync into a *running* immich's `mediaLocation` is a different shape of
  problem than cloning a whole dataset.
- [ ] **3.4 Fix ownership.** rsync will land files as the source uid. Chown to
  the immich service user on the VM. *(The hofvarpnir migration hit exactly this
  — files arrived as uid 1000 and needed re-chowning to 999.)*
- [ ] **3.5 Stop immich on the VM, restore the dump, start it.** Immich runs its
  schema migrations on startup; watch the journal until they finish. Since both
  sides are 3.0.3 there should be **no** schema migration — if the journal shows
  a long migration run, something is not what you think it is; stop and check.
  If 0.1a found the source `vchord` older than nixpkgs' **1.1.1**, rebuild the
  vector indexes by hand after the restore — the module's automatic reindex does
  not fire on a fresh restore:

  ```sql
  REINDEX INDEX face_index;
  REINDEX INDEX clip_index;
  ```
- [ ] **3.6 Verify before trusting it:** photo count matches the source, albums
  and faces intact, thumbnails render, a new upload succeeds, mobile app syncs.
  Do **not** proceed until this passes.

## Phase 4 — Switch over and decommission

- [ ] **4.1** Repoint DNS / dashboard / uptime-forge / mobile clients to
  `immich.homelab.local`.
- [ ] **4.2 Move the PBS backup job.** Remove `104` from the **01:00** job; add
  `4348` to the **03:00** job (the block-level VM job). This is the payoff —
  verify the first run and record its duration against the 8 h baseline.
- [ ] **4.3** Confirm the Prometheus target is UP and the node appears on the
  dashboard.
- [ ] **4.4** Let the VM run a week with backups verified green, **then** destroy
  CT 104 and reclaim its storage. Keep the last pxar snapshot until you are sure
  — and it **is** a real safety net: verified clean 2026-08-01 once the verify
  job's bogus thread count was taken out of the picture.

---

## Verification

- First VM backup completes in **minutes, not hours** — the whole point.
  Concrete target from the 2026-08-01 measurements: **≲30 min** for the first
  (cold, no bitmap) run, benchmarked against `vm/4341`'s 16 min for 40 GiB.
  Anything approaching an hour means something is wrong.
- A second consecutive backup is faster still (dirty bitmap warm) — the other
  VMs land at **~7 min**; expect immich in that range once incremental.
- **The backup verifies green.** New criterion — the current pxar snapshot does
  not, so "it completed" is not sufficient evidence that it is restorable.
- `rate(node_pressure_io_waiting_seconds_total{instance="pve-gigabyte"}[15m])`
  no longer shows the multi-hour morning plateau.
- Photo/album/face counts match pre-migration.
- `immich.homelab.local` serves a valid step-ca cert.

## Risks and gotchas

- ~~**The 2.7.5 → 3.0.3 major upgrade is the one blocking risk.**~~ **Retired
  2026-07-29** — done in place on the LXC. The pgvecto.rs → VectorChord swap and
  the forward-only schema migration both happened on the source, where a PBS
  snapshot can roll them back.
- ~~**Two changes at once.**~~ **Resolved the way this section recommended:**
  the app upgrade and the platform move are now sequential and independently
  revertible. Keep them that way — do not bundle another immich version bump
  into the cutover. If a flake update lands a newer immich before Phase 3, either
  upgrade the LXC to match first or pin `services.immich.package` on the VM to
  3.0.3 for the cutover and bump afterwards.
- **Version parity is now the thing to watch, not version distance.** Three
  things must line up at restore: immich version (3.0.3 both sides — hold it
  there), Postgres major (0.1b), and `vchord` version (0.1a; nixpkgs has 1.1.1,
  and a mismatch means a manual `REINDEX` in 3.5, not a failure).
- ~~**Dirty bitmaps are lost on VM shutdown or host reboot**, so an occasional
  full sequential read of the disk still happens.~~ **Measured 2026-08-01 and
  effectively retired.** `vm/4341`'s first-ever backup — no bitmap, full block
  read of a 40 GiB disk — took **16 minutes**. Extrapolated to an ~80 GiB immich
  VM that is roughly **30 minutes cold**, against 8 h 32 m for the current pxar
  walk. The worst case after migration beats the best case before it by ~17×.
  Post-reboot full runs are a non-event, not a caveat.
- ~~**The existing pxar snapshot is corrupt.**~~ **Withdrawn same day.** The
  `failed` verification state was an artifact of the verify job's
  `read-threads=16` against the S3 backend, not damage. Re-verified single-
  threaded on 2026-08-01: **0 errors**. Immich *does* have a restorable backup.
  The ordinary Phase 3 care still applies — keep CT 104 intact until the VM is
  populated and verified — but there is no elevated risk here.
- **This does not make immich faster.** The photos stay on the same 2 HDDs.
  Thumbnail generation, ML jobs, and library scans are random-IO heavy and will
  be exactly as slow as they are today. The migration fixes the *backup*
  pathology, not the runtime one.
- **Do not rate-limit the backup as a workaround.** The job is already pinned at
  the pool's random-read floor; throttling only makes it run longer.

## Related storage work (separate, complementary)

The real fix for the underlying slowness is storage, and it helps immich either
way:

- **`zfs_arc_max` raised 3 GiB → 8 GiB** on `pve-gigabyte` (done 2026-07-28,
  persisted in `/etc/modprobe.d/zfs.conf`). Directly helps the pxar walk by
  caching metadata.
- **A `special` vdev (SSD mirror) on `zfs_pool`** — the targeted fix for this
  workload. Moves metadata and small blocks off the HDDs, which speeds up the
  pxar walk, immich's own thumbnail/scan work, and every other VM on the host.
  Cheaper and lower-risk than this migration; consider doing it first.
  (Superseded by [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md),
  which chose a separate `ssd_pool` over a `special` vdev — see its Decisions.)
  **Done 2026-08-07/08:** `ssd_pool` is built (2× Kingston A400 960 GB mirror,
  888 G) and CT 104's rootfs has been migrated onto it. "Consider doing it
  first" was the right call and it was taken.

## Unrelated to speed — resolved, no longer affects this plan

[`pbs-verify-failures.md`](./pbs-verify-failures.md) — `r2-store` verification
failed **every week since April**, `ct/104` among the rotating victims.
**Diagnosed 2026-08-01: the verify job's `read-threads=16` against the S3
backend, not data corruption.** The backups were always fine. Recorded here only
so the next reader does not re-panic at a `failed` verification flag on this
datastore.
