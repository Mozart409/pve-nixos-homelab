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

**Live facts (verified 2026-07-28):**

| Fact | Value |
| --- | --- |
| Last complete snapshot | `ct/104` @ 2026-07-27 01:13:46 UTC |
| `root.pxar.didx` | **79,383,215,582 B ≈ 74 GiB** (OS + library) |
| `catalog.pcat1.didx` | 29.7 MB — a very large catalog, i.e. a very high file count |
| Backup target | `pbs-r2` datastore (`r2-store`), selection `104` |
| Backup schedule | **`sun 01:00`** — moved off daily 2026-07-28 to stop the daily morning stall. An ~18 h run starting Sunday 01:00 still saturates the pool until ~19:00 Sunday. |
| immich on CT 104 | **2.7.5** → nixpkgs 3.0.3 is a **major** upgrade (see Phase 0.1) |
| Pool read ceiling | ~1.15 MB/s @ ~39 IOPS, ~30 KB avg read |
| immich in pinned nixpkgs | **3.0.3** (`services.immich` available) |
| Central Postgres (`homelab-database`) | `pkgs.postgresql_18` |
| Next free LAN IP | `192.168.2.185` (`.184` is the current highest) |
| Next free `vm_id` | `4348` |
| immich refs in this repo | **none** — greenfield host |

## Status

**Not started.** Planning only — nothing implemented.

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

- [ ] **0.1 Plan the 2.7.5 → 3.0.3 major upgrade.** *Blocking — the single
  highest risk in this migration.* The direction is safe (the LXC is **older**
  than nixpkgs, and immich migrates forward only), but this crosses a major
  version **and** an extension swap.

  nixpkgs' `immich.nix` (lines ~81–93) states:

  > `database.enableVectors` has been deprecated as pgvecto.rs is no longer
  > available. From now on, vectorchord is used instead.

  So 2.7.5 almost certainly stores its smart-search embeddings under
  **pgvecto.rs**, while 3.0.3 requires **VectorChord**. A plain
  `pg_dump`/`pg_restore` will not carry a vector column and its index across
  extensions. Before touching data:

  - [ ] Confirm which vector extension CT 104's Postgres actually has
        (`\dx` in the immich DB).
  - [ ] Read immich's 3.0 release notes and upgrade guide for the documented
        pgvecto.rs → VectorChord path, and whether intermediate versions must be
        stepped through rather than jumping straight to 3.0.3.
  - [ ] Establish whether embeddings can simply be **dropped and regenerated**
        after cutover. If smart search can rebuild from the originals, that
        sidesteps the extension migration entirely — at the cost of a
        CPU-expensive re-index, which interacts with the ML decision in
        "Open" above. This is likely the pragmatic path; confirm it first.
  - [ ] Rehearse the restore on a throwaway VM before the real cutover.

- [ ] **0.1b** Also confirm the Postgres **major** version on CT 104. A
  cross-major dump/restore is fine, but it changes the `pg_dump` invocation and
  must be planned alongside the extension change.
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

- [ ] **1.1 `iac/main.tf`** — add `immich_vm`: `vm_id = 4348`, `node_name =
  "pve-gigabyte"`, 4 cores (`type = "host"`), memory `dedicated = 8192`.
  **Set `floating = 0` / omit ballooning** — see the jellyfin balloon incident
  (2026-07-28: host memory pressure squeezed jellyfin 3.83 GiB → 1.85 GiB
  mid-workload). Single `scsi0` disk on `zfs_pool`, 250 GB. Add to outputs.
- [ ] **1.2 `tofu apply`** in `iac/`.
- [ ] **1.3 `hosts/immich/configuration.nix`** — import `common.nix`,
  `tailscale.nix`, `step-ca-trust.nix`. Static IP `192.168.2.185/24`, gateway
  `192.168.2.1`. Node exporter with `["systemd" "processes"]`. Firewall: 22, 443,
  9100, `trustedInterfaces = ["tailscale0"]`.
- [ ] **1.4 `flake.nix`** — add to `hostAddrs`, `nixosConfigurations` (`mkHost`),
  and `colmenaHive`.
- [ ] **1.5 `hosts/dns/configuration.nix`** — A + PTR records for
  `immich.homelab.local` → `192.168.2.185`.
- [ ] **1.6 `hosts/otel/configuration.nix`** — Prometheus scrape job
  `immich-node`, target `192.168.2.185:9100`, label `instance = "homelab-immich"`.
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
  touching anything else.
- [ ] **3.3 rsync the library** to the new VM's `mediaLocation`. 74 GiB off an
  HDD pool of small files — **expect many hours**, same physics as the backup.
  Run it in `tmux`/`screen`, use `rsync -aHAX --info=progress2`, and be ready to
  resume.
- [ ] **3.4 Fix ownership.** rsync will land files as the source uid. Chown to
  the immich service user on the VM. *(The hofvarpnir migration hit exactly this
  — files arrived as uid 1000 and needed re-chowning to 999.)*
- [ ] **3.5 Stop immich on the VM, restore the dump, start it.** Immich runs its
  schema migrations on startup; watch the journal until they finish.
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
  CT 104 and reclaim its storage. Keep the last pxar snapshot until you are sure.

---

## Verification

- First VM backup completes in **minutes, not hours** — the whole point.
- A second consecutive backup is faster still (dirty bitmap warm).
- `rate(node_pressure_io_waiting_seconds_total{instance="pve-gigabyte"}[15m])`
  no longer shows the multi-hour morning plateau.
- Photo/album/face counts match pre-migration.
- `immich.homelab.local` serves a valid step-ca cert.

## Risks and gotchas

- **The 2.7.5 → 3.0.3 major upgrade (0.1) is the one blocking risk.** Everything
  else is recoverable; a forward-only schema migration combined with a
  pgvecto.rs → VectorChord extension swap is not. Rehearse it on a throwaway VM.
  Treat "drop and regenerate embeddings" as the likely escape hatch.
- **Two changes at once.** This migration bundles a platform move (LXC → VM) with
  a major app upgrade. If the cutover goes wrong it will not be obvious which
  caused it. Consider upgrading immich **in place on the LXC first**, verifying,
  and only then moving the platform — slower, but each step is independently
  revertible.
- **Dirty bitmaps are lost on VM shutdown or host reboot**, so an occasional full
  sequential read of the disk still happens. That is ~1 h/TB sequential on this
  pool — vastly better than 18 h random, but not free.
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
