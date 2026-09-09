# Move `dns` and `cache` to `ssd_pool` + XFS

Put both guests on the flash tier with the XFS layout every new VM here already
uses (`modules/disko-xfs.nix`), replacing their btrfs roots. Phase 2 of
[`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md), applied to two of
the 18 VM root disks that phase is about.

**The two halves are not equally cheap.** Moving a disk is an online, in-place
`move-disk` the bpg provider does for you. Changing the *filesystem* is a **full
reinstall** — `disko` only ever runs under `nixos-anywhere`, never during
`colmena apply`.

**The two hosts are not equally cheap either**, and that is the thing to
internalise before starting:

| | `dns` | `cache` |
| --- | --- | --- |
| Already on `ssd_pool`? | **No** — needs the move | **Yes**, moved manually 2026-08-19 |
| Disk work | in-place move + grow (20→32 GB) | **destroy + recreate** (200→50 GB — a shrink cannot be done in place) |
| Root filesystem | btrfs → XFS | btrfs → XFS |
| State to preserve | **None** — stateless by design | **~4.1 GB of attic NAR storage, whose index is in Postgres on another host** |
| RAM vs kexec's ~1.5 GB | 1536 unpinned — **borderline** | **963 MB — below the line, will fail** |
| agenix secrets to re-key | 3 | 6 |
| Outage hurts | the whole LAN's name resolution (softened, see below) | almost nothing |

`dns` is the scarier-sounding host and the easier job. `cache` is the reverse.
**Do `dns` first** — it is the clean rehearsal of the exact same procedure, and
its failure modes are all well-understood.

## Status — repo changes landed, migration not started (2026-09-09)

- ✅ `hosts/dns/configuration.nix` + `hosts/cache/configuration.nix` import `modules/disko-xfs.nix`
- ✅ `iac/main.tf` `dns_vm`: `ssd_pool`, 32 GB, `discard = "on"`
- ✅ `iac/main.tf` `cache_vm`: 200 → **50 GB**, memory → 2048/1024, `discard = "on"` (already on `ssd_pool`)
- ✅ both closures pre-built on wotan (so neither install needs DNS of its own)
- ⬜ everything below

---

## Live facts (verified 2026-09-09)

### `dns`

| Fact | Value |
| --- | --- |
| Guest | VM **4326**, `homelab-dns`, **192.168.2.145** (static, `ens18`) |
| Disk | single `scsi0` → `/dev/sda`, **20 GB**, **`zfs_pool`** |
| Layout today | 1 M BIOS + 1 G ext4 `/boot` + 15 G **btrfs** (`/root` `/home` `/nix` `/var` + 4 G swapfile subvol) |
| Root usage | **14 G of 15 G — 89 %** |
| `iac/main.tf` said | `size = 16` — **stale**, below the live 20 GB; a plan would have tried to shrink and the provider cannot. Now 32. |
| Memory | `dedicated 1536 / floating 768` — **not pinned** |
| agenix | `tailscale-auth-key`, `fleet-enroll-secret` (via `users`), `attic-push-token` |
| Tailscale role | **subnet router** — advertises `192.168.2.0/24`, and the tailnet's split-DNS target for `homelab.local` |

### `cache`

| Fact | Value |
| --- | --- |
| Guest | VM **4340**, `homelab-cache`, **192.168.2.175** (static, `ens18`) |
| Disk | single `scsi0` → `/dev/sda`, **200 GB**, already **`ssd_pool`** → **recreated at 50 GB** |
| Layout today | 1 M BIOS + 1 G ext4 `/boot` + 199 G **btrfs** |
| Root usage | **18 G of 199 G — 9 %** (15 G `/nix/store` + 4.1 G attic) — hence the shrink to 50 GB |
| Memory | was `dedicated 1024 / floating 1024`; **963 MB total** in-guest — below the kexec floor, now `2048 / 1024` in `iac/main.tf` |
| agenix | `attic-db-url`, `attic-server-token`, `garage-rpc-secret`, `attic-push-token` (explicit `hostCache`) + `tailscale-auth-key`, `fleet-enroll-secret` (via `users`) |
| `atticd` | **active** as a **static** `atticd` user (uid 993/gid 990), storage `type = "local"` at `/var/lib/atticd/storage` — **4,122,133,565 bytes**; GC retention **6 months** |
| `atticd` database | **PostgreSQL on the `database` host** (192.168.2.134), via `attic-db-url.age` — **not on this guest** |
| `garage` | **inactive**, `/var/lib/garage` = **4.0 KB** — see "Garage is dead weight" below |

Both by-id pins exist (`scsi-0QEMU_QEMU_HARDDISK_drive-scsi0`), so
`disko-xfs.nix`'s default device is correct on both; neither needs an override.

---

## Three traps worth reading before you start

### 1. `cache` will desynchronise its own cache if you just wipe it

This is the finding that shapes the whole `cache` procedure.

atticd keeps **NAR chunks locally** (`/var/lib/atticd/storage`, 4.1 GB) but its
**index in Postgres on the `database` host**. The wipe destroys one and leaves
the other fully populated. The result is not an empty cache — it is a **lying**
cache: attic keeps serving narinfos for store paths whose NAR data no longer
exists, and every client gets a 404 on fetch. That is strictly worse than having
no cache at all, and it fails in a way that looks like a network problem.

Two consistent endings, pick one in Phase B0:

- **Preserve** — `rsync` the 4.1 GB off before the wipe and back after. Storage
  and index stay in step, the cache stays warm. 4 GB over the LAN is a couple of
  minutes; this is the default.
- **Reset both** — wipe the guest *and* empty the attic index, giving a clean
  empty cache that refills itself. Cheaper to execute, but note the memory on
  `just attic-init` says it was "written but never executed; treat as
  unverified", so you would be debugging a bringup script during a migration.

Preserve. The other option trades a 4 GB copy for an unverified script.

### 2. `cache` does not have enough RAM to kexec

`nixos-anywhere` kexecs a NixOS installer into RAM and wants ~1.5 GB. `cache`
reports **963 MB total**. This is not "tight" like `dns` — it is below the line,
and the install is expected to fail at the kexec step.

**Already handled declaratively:** because the shrink forces a VM recreate
anyway (trap 3), `iac/main.tf` now sets `dedicated = 2048 / floating = 1024`, so
the rebuilt guest boots above the floor and still balloons back down to its
steady-state 1 GB rather than becoming a permanent non-donor. Nothing manual is
needed — but if you ever reinstall this host *without* recreating it, the balloon
may have taken it under again, and the fallback is:

```bash
qm set 4340 --memory 2048 --balloon 2048     # then reboot the guest to apply
```

`dns` has the softer version of the same problem: `dedicated 1536 / floating
768`, **unpinned**, on an oversubscribed host
([`pve-gigabyte-memory-oversubscription.md`](./pve-gigabyte-memory-oversubscription.md)),
so the balloon may have taken it below 1.5 GB by the time you get there. Check
`free -m` first and un-balloon with `qm set 4326 --balloon 1536` if it has.

### 3. The `cache` disk shrink cannot be applied in place

`size = 200` → `50` is **not** the same kind of change as the `ssd_pool` move.
Proxmox and the bpg provider can only ever **grow** a disk; a shrink is refused
outright — the same trap the stale `size = 16` on `dns_vm` would have sprung.
Applying it requires **destroying and recreating** the disk, which is why it is
bundled into the reinstall that already discards this guest's data instead of
being done separately later, at the cost of a second outage.

Sizing rationale: 18 G of the 200 G is in use (15 G `/nix/store`, 4.1 G attic),
so 50 G leaves ~45 G of root after the XFS layout's 1 G `/boot` and 4 G swap.
**The 4.1 G is not steady state** — atticd's `garbage-collection` keeps a
6-month `default-retention-period` and the cache is roughly a month old, so
nothing has aged out yet. Watch it as it fills; growing later is a manual
guest-side `growpart` + `xfs_growfs` (XFS grows but never shrinks), not a
`tofu apply`. If it turns out to climb faster than expected, shortening that
retention period is the cheaper lever than resizing again.

### Why the blast radius is smaller than it looks

**`dns`:** `modules/dns-client-cache.nix` puts a local unbound stub on **every
host except this one**, with `serve-expired` + `serve-expired-ttl 1800` and a
30-minute `cache-min-ttl` floor. While `dns` is down, other hosts answer
`*.homelab.local` from stale cache rather than failing, and `modules/common.nix`
lists `192.168.2.1` as a second nameserver for public names. A window well under
30 minutes is absorbed almost invisibly. What does *not* survive: any name first
resolved after a stub's cache ages out, and any tailnet client reaching the LAN
through the subnet route.

**`cache`:** almost nothing depends on it. Only `hosts/development` imports
`modules/attic-cache.nix` as a substituter, and nix falls back to
`cache.nixos.org` silently. `modules/attic-push.nix` runs on every node but
fires `systemctl start --no-block … || true`, so a failed push **never** blocks a
deploy. Losing this host for an hour costs rebuild time on `development` and
nothing else.

### Why the format change costs a reinstall

`disko` runs exactly once, during `nixos-anywhere`. Editing the disko module and
running `colmena apply` is a **no-op for disks** — the generated mounts key off
`/dev/disk/by-partlabel/*`, so the guest keeps its btrfs root and nothing tells
you otherwise. There is no in-place btrfs→XFS conversion.

### Garage is dead weight

`garage` is `inactive` with **4.0 KB** of data, while `hosts/cache/garage/` is
still imported and Caddy still routes `/s3/*` to `localhost:3900`. atticd uses
`storage.type = "local"`, not S3, so nothing needs it. Not part of this
migration — but this is the moment you would notice, and removing the module
(and `garage-rpc-secret.age`) is a clean follow-up.

---

## Part A — `dns` (do this one first)

### A0 · Pre-flight

- [ ] **A0.1 Verify `ssd_pool` has room.** The 888 G mirror held only immich
      (~70 G) when [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md)
      was measured on 2026-08-08; `woodpecker` (100 G), `cache` (200 G) and
      `k3s-cntrl-1` (64 G) have landed since, so re-measure rather than trust
      that number: `zpool list ssd_pool` on `pve-gigabyte`.
- [ ] **A0.2 Confirm the closure is built**, so the install never needs a name
      resolved while the resolver is down (the `homelab-mcp` flake input is
      `git+https://forgejo.homelab.local/…`):
      ```bash
      nix build --no-link --print-out-paths '.#nixosConfigurations.dns.config.system.build.toplevel'
      ```
      Done once on 2026-09-09; re-run after any further edit.
- [ ] **A0.3 Check the guest has its memory** — `ssh amadeus@192.168.2.145 free -m`
      should show MemTotal near 1500, not 768. See trap 2 above.
- [ ] **A0.4 Nothing to back up.** unbound serves a static zone from the Nix
      store, the step-ca cert is re-issued over ACME on first boot, and the
      Tailscale identity is replaced regardless.

### A1 · Move the disk (online, non-destructive)

Do this **before** the reinstall, so XFS lands on the disk in its final home and
the move stays independently revertible.

- [ ] **A1.1 Plan and read it carefully.** `datastore_id` must show as an
      **in-place update** — no `# forces replacement`, `0 to destroy`. Confirmed
      for `woodpecker` on 2026-08-15; verify rather than assume.
      ```bash
      just iac-plan     # or: cd iac && tofu plan -target=proxmox_virtual_environment_vm.dns_vm
      ```
      The `pg` backend reads `PG_CONN_STR`; without it the plan dies with
      `dial tcp [::1]:5432: connection refused`.
- [ ] **A1.2 Apply.** `just iac-apply`. Proxmox streams the zvol with the guest
      running; 20 GB *off* a ~78 IOPS pool is not instant.
- [ ] **A1.3 Confirm.** `qm config 4326` → `scsi0: ssd_pool:vm-4326-disk-0,discard=on,size=32G`.
      The guest is still btrfs and still sees only 20 GB; Phase A2 repartitions
      the whole disk anyway.

### A2 · Reinstall onto XFS (destructive — this is the outage)

- [ ] **A2.1** `ssh-keygen -R 192.168.2.145` — the reinstall generates a new host
      key and both nixos-anywhere and colmena will otherwise refuse.
- [ ] **A2.2** `just deploy dns 192.168.2.145` (type `dns` at the guard prompt).
      Full config, **not** `deploy-minimal` + colmena: this host has a static IP
      and `minimal` is DHCP with a different layout (AGENTS.md §6).
- [ ] **A2.3 Confirm the format actually changed** — the one thing a green deploy
      does not prove:
      ```bash
      ssh amadeus@192.168.2.145 'findmnt -no FSTYPE,SIZE /; lsblk -o NAME,SIZE,FSTYPE'
      # expect: xfs, ~27G root, 4G swap partition
      ```
- [ ] **A2.4 Confirm unbound answers** before touching anything else:
      ```bash
      dig +short @192.168.2.145 forgejo.homelab.local     # 192.168.2.178
      dig +short @192.168.2.145 nixos.org                 # forwarding works
      ```
      LAN DNS is restored here; the rest is reinstall follow-up.

### A3 · agenix re-key

New host key ⇒ `age: error: no identity matched any of the recipients`.

- [ ] **A3.1** `just get-host-key 192.168.2.145`, replace `hostDns` in
      `secrets/secrets.nix:13`.
- [ ] **A3.2** Re-encrypt the three affected secrets. ⚠️ **Ask before running
      `just reencrypt`** — amadeus corrected that as the wrong follow-up on
      2026-08-04 and the right procedure was never written down. Targeted form:
      ```bash
      cd secrets
      agenix -e tailscale-auth-key.age -i ~/.config/age/keys.txt   # save unchanged
      agenix -e fleet-enroll-secret.age -i ~/.config/age/keys.txt
      agenix -e attic-push-token.age -i ~/.config/age/keys.txt
      ```
      Use a **real interactive editor**: agenix runs `$EDITOR` with a stripped
      PATH, and an editor *script* silently writes an **empty** secret.
- [ ] **A3.3** `just colmena-apply-host dns` — targets the raw IP from
      `hostAddrs`, so it works with or without healthy DNS.
- [ ] **A3.4** Verify: `sudo ls -l /run/agenix/` and
      `systemctl is-active tailscaled osqueryd` on the host.

### A4 · Tailscale — re-approve the node *and its subnet route*

The reinstalled guest joins as a **new, unapproved node** (usually renamed
`homelab-dns-1`, since the old node still holds the base name), and an unapproved
node has no netmap. **This node is the tailnet's subnet router for
`192.168.2.0/24`** — until the route is re-approved, remote tailnet clients lose
the entire homelab LAN, not just this host.

- [ ] **A4.1** Delete the stale `homelab-dns` at
      <https://login.tailscale.com/admin/machines> so the new node reclaims the name.
- [ ] **A4.2** Approve the new node.
- [ ] **A4.3** Approve the **subnet route** `192.168.2.0/24` — a separate toggle
      from node approval, and the one that silently breaks remote access.
      `extraUpFlags` re-advertises it automatically on a fresh install
      (`tailscaled-autoconnect` does run `tailscale up` when not already
      connected), so this is console-side only.
- [ ] **A4.4** Confirm split-DNS still maps `homelab.local` → `192.168.2.145`
      (unchanged LAN IP, but check while you are there).
- [ ] **A4.5** Verify from a remote tailnet client: `dig +short
      @192.168.2.145 forgejo.homelab.local` and `ping 192.168.2.178`.

### A5 · Certificates and smoke test

- [ ] **A5.1** `curl -sS -o /dev/null -w '%{http_code}\n' https://dns.homelab.local`.
      If stuck at 000, it is the step-ca ACME `badNonce` storm: stop Caddy →
      restart step-ca on `ca` → start Caddy, **in that order** (either alone fails).
- [ ] **A5.2** Tailscale cert for `homelab-dns.dropbear-butterfly.ts.net` — needs
      A4 done first (`get_certificate tailscale` fails on an unapproved node).
- [ ] **A5.3** Prometheus: the `dns-node` job is deliberately the one target kept
      on a **raw IP** so the resolver stays observable when unbound is down.
      Nothing to change — confirm it is `UP`.
- [ ] **A5.4** Fleet/osquery re-enrols with a new identity; confirm it appears
      rather than lingering as a duplicate.
- [ ] **A5.5** Lab-wide smoke test via the dashboard `health_checks` URLs: `200`,
      `302`, `406` are healthy; `000` is down.

---

## Part B — `cache`

Only after Part A is green. The disk is **already on `ssd_pool`**, so there is no
Phase A1 equivalent — the `discard = "on"` addition applies on the next
`just iac-apply` and does nothing until the guest runs XFS.

### B0 · Pre-flight — **the data comes first**

- [ ] **B0.1 Back up the attic NAR storage** (trap 1 — do not skip):
      ```bash
      sudo rsync -aHAX --numeric-ids --info=progress2 \
        amadeus@192.168.2.175:/var/lib/atticd/storage/ \
        /path/to/atticd-storage-backup/
      ```
      Needs `sudo` on the remote side to read it; adjust to taste (`ssh … sudo
      tar -C /var/lib/atticd -cf - storage | …` also works). Verify the byte count
      matches the source exactly — it was **4,122,133,565 bytes** on 2026-09-09
      (`du -sb`).
- [ ] **B0.2 Note the Postgres index is untouched** and lives on the `database`
      host. That is exactly why C0.1 matters — restoring storage is what keeps
      the two in step.
- [ ] **B0.3 Recreate the VM at 50 GB** (traps 2 and 3). The shrink and the
      memory bump both land here, and **B0.1 must already be done** — this
      destroys the disk:
      ```bash
      cd iac
      tofu destroy -target=proxmox_virtual_environment_vm.cache_vm
      tofu apply                      # or: just iac-apply
      ```
      The VM returns as **4340** with a 50 GB `ssd_pool` disk, `discard = on`,
      2048/1024 memory, and its static **192.168.2.175** from the cloud-init
      block — i.e. the ordinary new-host starting point, running Debian.
      Confirm `qm config 4340` and `free -m` (~2 GB) before continuing.
- [ ] **B0.4 Confirm the closure is built:**
      ```bash
      nix build --no-link --print-out-paths '.#nixosConfigurations.cache.config.system.build.toplevel'
      ```
- [ ] **B0.5** Nothing else on this guest is stateful: `/home` is 544 KB and
      `/var/lib/garage` is 4.0 KB (garage is inactive — see "Garage is dead
      weight"). The 15 G `/nix/store` rebuilds itself.

### B1 · Reinstall onto XFS (destructive)

- [ ] **B1.1** `ssh-keygen -R 192.168.2.175`
- [ ] **B1.2** `just deploy cache 192.168.2.175` (type `cache` at the prompt).
      Full config, not `deploy-minimal`: static IP, same reasoning as A2.2.
      After B0.3 the target is a fresh Debian cloud image rather than the old
      NixOS host, which is the normal nixos-anywhere starting point.
- [ ] **B1.3** Confirm the format:
      ```bash
      ssh amadeus@192.168.2.175 'findmnt -no FSTYPE,SIZE /; lsblk -o NAME,SIZE,FSTYPE'
      # expect: xfs, ~45G root, 4G swap partition
      ```

### B2 · agenix re-key (six secrets, not three)

- [ ] **B2.1** `just get-host-key 192.168.2.175`, replace `hostCache` in
      `secrets/secrets.nix:9`.
- [ ] **B2.2** Re-encrypt, same cautions as A3.2:
      ```bash
      cd secrets
      agenix -e attic-db-url.age -i ~/.config/age/keys.txt
      agenix -e attic-server-token.age -i ~/.config/age/keys.txt
      agenix -e garage-rpc-secret.age -i ~/.config/age/keys.txt
      agenix -e attic-push-token.age -i ~/.config/age/keys.txt
      agenix -e tailscale-auth-key.age -i ~/.config/age/keys.txt
      agenix -e fleet-enroll-secret.age -i ~/.config/age/keys.txt
      ```
- [ ] **B2.3** `just colmena-apply-host cache`
- [ ] **B2.4** Verify `/run/agenix/` is populated. `atticd` **will not start**
      without `attic-db-url` — it panics with an explicit message if the env var
      is missing (`hosts/cache/attic/default.nix`), which is the good failure.

### B3 · Restore the NAR storage

- [ ] **B3.1 Stop atticd** before writing into its state dir:
      `sudo systemctl stop atticd`
- [ ] **B3.2 Restore, then chown by NAME** — this is the step that bites.
      `hosts/cache/attic/default.nix` already runs atticd as a **static**
      `atticd` user (`DynamicUser = no`), precisely because the upstream
      DynamicUser default once broke this host: state written as uid 65534 came
      back as uid 65312 and every upload failed with `Failed to read version
      file: Permission denied`, since `storage/VERSION` is mode 0600.
      **That fix does not survive a reinstall on its own.** `isSystemUser`
      allocates the numeric uid at activation and records it in
      `/var/lib/nixos/uid-map` — which the wipe destroys — so the fresh install
      can pick a different number. Today it is **uid 993 / gid 990**; do not
      assume it comes back as that.
      ```bash
      sudo rsync -aHAX --numeric-ids /path/to/atticd-storage-backup/ /var/lib/atticd/storage/
      sudo chown -R atticd:atticd /var/lib/atticd     # by NAME, never by number
      sudo systemctl start atticd
      ```
      `--numeric-ids` on the restore preserves the *old* uid, which is why the
      chown-by-name afterwards is mandatory rather than belt-and-braces.
- [ ] **B3.3 Verify storage and index agree** — pick a store path the cache
      already knows and fetch it end to end, rather than trusting a green unit:
      ```bash
      curl -sS -o /dev/null -w '%{http_code}\n' https://cache.homelab.local/health   # 200
      nix path-info --store https://cache.homelab.local/homelab <some-cached-path>
      ```
      A narinfo hit followed by a NAR 404 is exactly the desync from trap 1.

### B4 · Tailscale + certificates

- [ ] **B4.1** Delete the stale `homelab-cache` node, approve the new one. No
      subnet route on this host — simpler than A4.
- [ ] **B4.2** `curl -sS -o /dev/null -w '%{http_code}\n' https://cache.homelab.local/health`
      → 200. Same `badNonce` recovery as A5.1 if it sits at 000.
- [ ] **B4.3** Confirm `development` can substitute from it again (it is the only
      importer of `modules/attic-cache.nix`).
- [ ] **B4.4** Trigger a push from any host and confirm it lands:
      `sudo systemctl start attic-push-system.service`, then check its journal.
      Remember pushes fail silently by design (`|| true`), so read the unit
      rather than the deploy output.

---

## Part C — Fold the findings back

- [ ] **C.1** Tick both hosts off Phase 2 in
      [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md).
- [ ] **C.2** Record the measured `dns` move time and any before/after IOPS —
      that table is the evidence base for moving the remaining ~16 root disks.
- [ ] **C.3** Decide whether `cache` keeps the 2 GB from B0.3, and whether `dns`
      gets `floating = dedicated`. Every guest that hit balloon starvation here
      (`harbor`, `forgejo`, `woodpecker`, `k3s-cntrl-1`) ended up pinned — but a
      pinned guest is a balloon **non-donor**, so weigh it against
      [`pve-gigabyte-memory-oversubscription.md`](./pve-gigabyte-memory-oversubscription.md).
- [ ] **C.4** Consider removing the dead Garage module and `garage-rpc-secret.age`.

---

## Rollback

- **`dns`, after A1 and before A2:** revert `datastore_id` to `zfs_pool` and
  apply. The guest never stopped; nothing was lost.
- **Either host, once the reinstall starts:** there is no rollback, only forward
  — the disk is wiped the moment disko runs. Recovery is the same command again.
  `dns` is stateless (A0.4), so a second `just deploy` is a complete fix.
  `cache` is a complete fix **only if B0.1 was done**; without that backup, the
  4.1 GB is gone and you must reset the Postgres index too, or the cache lies.
- **If DNS stays down and you need the lab back now:** other hosts survive on
  their `serve-expired` stubs plus the `192.168.2.1` fallback. Colmena targets
  `dns` by raw IP, so you can always redeploy the resolver without the resolver.
