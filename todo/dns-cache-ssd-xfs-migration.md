# Get `dns`, `cache` and `ca` off btrfs

Three jobs that started as one. `dns` moves to the flash tier and swaps its btrfs
root for the XFS layout every new VM here uses (`modules/disko-xfs.nix`) — Phase 2
of [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md). `cache` was
going to get the same treatment until its traffic was measured, at which point
the better answer turned out to be **deleting it**. `ca` joined the list when it
turned up two percentage points from the same ENOSPC wedge that took `dns` down
mid-migration; it gets XFS but **stays on `zfs_pool`** — its problem was btrfs,
not IOPS.

**Moving a disk is cheap; changing its filesystem is not.** A pool move is an
online, in-place `move-disk` the bpg provider does for you. A format change is a
**full reinstall** — `disko` only ever runs under `nixos-anywhere`, never during
`colmena apply`. Editing the disko module and running `colmena apply` is a
**no-op for disks**: the generated mounts key off `/dev/disk/by-partlabel/*`, so
the guest keeps its old filesystem and nothing tells you otherwise.

> ## ⚠️ 2026-09-09 — `dns` filled its disk and took the lab down
>
> This stopped being hypothetical mid-migration. A fleet-wide `colmena apply`
> pushed closures onto `dns`, whose btrfs root was at 89 %, and **btrfs ran out
> of metadata space**. unbound could not `rename()` its `root.key`, crash-looped
> **1,674 times**, and LAN DNS went down — which then hung every *other* host's
> push, because they all still carried `https://cache.homelab.local/homelab` as a
> substituter and the *target* is what fetches from it during a colmena push.
> `otel` sat 19 minutes on `copying path … from cache.homelab.local`. **The cache
> host was healthy the whole time** (HTTP 200 in 14 ms by IP); it was collateral,
> not cause — the name simply stopped resolving when unbound died, and nix waits
> out `stalled-download-timeout` (300 s) per path rather than failing fast.
>
> **`df` cannot show you this failure.** It reported 1.8 G free while writes
> failed with ENOSPC, because that free space was trapped inside *data* chunks:
>
> ```
> Device allocated:  15.00GiB / 15.00GiB   ← unallocated: 1.00 MiB
> Data,single:       13.96GiB used 12.18GiB   ← what df counts as "free"
> Metadata,DUP:       522MiB  used  489MiB    ← 93.8 %, and cannot grow
> ```
>
> Always check `btrfs filesystem usage /`, not `df`, on these hosts.
>
> **What did not work:** `nix-collect-garbage -d` (deleting files itself needs
> metadata) and `btrfs balance -dusage=0` ("had to relocate 0 out of 18 chunks"
> — no chunk was completely empty).
>
> **What worked:** deleting the 4 GB btrfs swapfile to free *data*, then a
> balance to hand whole chunks back as unallocated so metadata could grow:
>
> ```bash
> sudo swapoff -a && sudo rm -f /.swapvol/swapfile
> sudo btrfs balance start -dusage=50 /
> ```
>
> Result: unallocated 1.00 MiB → **1.50 GiB**, metadata 93.8 % → **66.7 %**,
> free 1.8 G → **4.3 G**, unbound `active`. **`dns` is currently running with no
> swap** until it is reinstalled (the XFS layout gives it a real 4 GB partition).
>
> This is the strongest possible argument for Part A: on XFS there is no
> data/metadata chunk split to exhaust, and the new disk is 32 GB on flash
> instead of 15 GB on a 78-IOPS HDD pair.
>
> ### `ca` was found in the same state, one point behind — rescued the same day
>
> Checking the other btrfs guests turned up **`ca` at 92.8 % metadata with
> 1.00 MiB unallocated** — `dns` wedged at 93.8 %. This is the host that issues
> every step-ca certificate in the lab, so its ENOSPC would have stopped ACME
> renewals fleet-wide.
>
> The cause was the same and slightly worse: its root partition was **15 GiB
> inside a 20 GB disk**. Someone had grown the Proxmox disk 16 → 20 GB (probably
> when it first filled) but never grew the partition, so btrfs never saw the
> extra 4 GB — and `iac/main.tf` still declared `size = 16`, which made every
> plan propose an impossible **shrink**. That is what produced
> `cannot delete boot disk "ide0"` on `ca_vm` and `dns_vm` during the
> 2026-09-09 apply: the error was the symptom, the stale size was the cause.
> Fixed in `main.tf` (16 → 20, matching reality).
>
> Rescued by claiming the space that was already paid for — no reinstall, no
> downtime. NixOS has no `growpart`, so `sfdisk` does it (`sda3` is the last
> partition, so extending it is safe):
>
> ```bash
> echo ", +" | sudo sfdisk -N 3 --no-reread --force /dev/sda
> sudo partx -u /dev/sda
> sudo btrfs filesystem resize max /
> ```
>
> Result: device 15 → **19 GiB**, unallocated 1 MiB → **3.50 GiB**, metadata
> 92.8 % → **61.9 %**, free 1.5 G → **5.0 G**. (The partition-table backup to
> `/tmp` failed with ENOSPC first — `/tmp` was on the full filesystem. A good
> reminder to write that backup somewhere else.)
>
> **Check the remaining btrfs guests for this shape** — `btrfs filesystem usage /`
> on each, looking for near-zero `unallocated` with high `Metadata` usage. Any
> guest whose partition is smaller than its disk has free headroom one `sfdisk`
> away.

## Status (2026-09-09)

Repo:

- ✅ `hosts/dns/configuration.nix` imports `modules/disko-xfs.nix`
- ✅ `iac/main.tf` `dns_vm`: `ssd_pool`, 32 GB, `discard = "on"`, cloud-init
      pinned to the static `192.168.2.145` (it was `dhcp`, which would have made
      a recreated guest come up on a lease you had to go hunting for)
- ✅ `iac/main.tf` `ca_vm`: `ssd_pool`, 32 GB, blank disk + installer ISO,
      `discard`/`raw`, memory `2048/2048` (was: stale `size = 16` → live `20`)
- ✅ `cache` decommissioned in the repo — Part B lists exactly what was unwired
- ✅ `dns` closure pre-built on wotan
- ⬜ `hosts/ca/configuration.nix` still on btrfs **deliberately** — see C1b

Infrastructure:

- ✅ `cache` VM **destroyed**
- ✅ **Part A DONE** — `dns` reinstalled onto XFS on `ssd_pool`. Root went from
      15 G btrfs at 89 % to **26.9 G XFS**; swap is now a real 4 G partition
      rather than a btrfs swapfile; unbound active and resolving, and
      `cache.homelab.local` correctly NXDOMAINs
- ✅ `ca` rescued from the pending wedge (`sfdisk` + `btrfs resize`; 19 GiB
      device, 3.5 GiB unallocated, metadata 61.9 %), memory raised to 2 GB and
      its step-ca Badger DB repaired after the reboot — no longer urgent
- ✅ agenix re-keyed for `dns` — new `hostDns` in `secrets.nix`, both
      `tailscale-auth-key.age` and `fleet-enroll-secret.age` re-encrypted, both
      decrypting on the host, `colmena apply` reports **Activation successful**
- ✅ Tailscale — node renamed back to `homelab-dns` (it joined as
      `homelab-dns-1`), approved, and `192.168.2.0/24` re-approved.
      `AdvertiseRoutes` confirms the route is live
- ✅ Both Caddy vhosts serving: `https://dns.homelab.local` **200** (step-ca) and
      `https://homelab-dns.dropbear-butterfly.ts.net` **200** (tailscale cert,
      after one `systemctl restart caddy` following the rename)
- ✅ Fleet `colmena apply` — all 10 nodes evaluated, pushed and activated (20 min
      wall clock; `otel` took 17 min and `ca` 10 min, both still on `zfs_pool`)
- ✅ The five commented-out hosts are **silenced in Alertmanager** (amadeus,
      2026-09-09), so their `TargetDown`/`ProbeFailed` alerts are expected and
      handled — not an open item.
- ✅ Five unreachable hosts commented out of `colmenaHive` first — `hermes`,
      `fleet`, `harbor`, `woodpecker`, `k3s-cntrl-1` all failed with "No route to
      host". Only the **hive entry** is commented; `hostAddrs` and
      `nixosConfigurations` are untouched, so the configs still evaluate and
      `just deploy` still works. That is the existing `zeroclaw` precedent.
- ✅ Dropped `attic` + `futo_notes` (B.3/B.4) — both databases, both roles and
      all four `.sql.zstd` dumps. The backup timers had already disappeared with
      the deploy, leaving only `appdb`, `hofvarpnir`, `romm`, `terraform`.
- ✅ `homelab-cache` already gone from the tailnet (B.6)
- ✅ Monitoring quiet (B.7) — no `cache`/`futo`/`notes` target, probe or cert
      subject left in Prometheus, and no alert fired for the disappearance
- ✅ **CA state backed up and verified** (2026-09-09 22:14) —
      `~/backups/step-ca-state-2026-09-09-2214.tar.gz` (57 M) plus an
      identity-only copy in `~/backups/step-ca-identity-2026-09-09/`. Both
      outside the repo. This is the C0 gate for Part C.
- ✅ **`database` certs rescued** — `database.homelab.{local,internal}` and
      `pgadmin.homelab.internal` went from **0.98 days** to **29.99 days**. A
      plain `systemctl restart caddy` cleared the DNS-outage backoff but then hit
      the badNonce storm; the D.5 sequence (stop Caddy → restart step-ca → start
      Caddy) is what actually fixed it.
- ✅ B.5 PBS/PVE backup job — checked, **no job references VM 4340**; Part B is
      closed
- ✅ **Part C DONE** — `ca` reinstalled onto **26.9 G XFS on
      `ssd_pool`**, step-ca active and serving `HTTP 200`, CA identity restored
      and **verified from another host against its system trust store** (not
      `-k`), agenix re-keyed, sync writes **~305× faster** (500 ms → 1.6 ms).
      See C7 for the full before/after table.
- ✅ **C6 Tailscale done** — root-caused to a broken
      `requires = ["agenix.service"]` in `modules/tailscale.nix` (agenix is an
      activation script, not a unit) plus the oneshot never re-running after a
      re-key. Both fixed declaratively with the `secretNonce` idiom; one deploy
      brought it back as `homelab-ca`, online with a full netmap.
- ✅ **CA trust confirmed fleet-wide** — `dns`, `database` and `otel` all reach
      `https://ca.homelab.local:8443/health` with **HTTP 200** through their
      system trust stores. **Part C is complete.**

---

## Ordering — two hazards that bite in practice

### 1. `dns` must NOT be in a `colmena apply` until it is reinstalled

Its committed config already describes the **XFS** layout, while the live disk is
still btrfs:

```
root: /dev/disk/by-partlabel/nixos   fsType xfs   ← live partition is btrfs
swap: /dev/disk/by-partlabel/swap                 ← does not exist; swap was a file
```

`colmena apply` never reformats (disko only runs under nixos-anywhere), so this
looks harmless and activates fine — but it writes a boot generation whose fstab
declares XFS for a btrfs partition. **The host keeps running and fails on the
next reboot.** `dns` gets *reinstalled* (`just deploy`), never applied, until
Part A is done.

Colmena has no negation for `--on`, so either deploy the other nodes explicitly
/ by tag, or simply do Part A first and then apply the fleet.

### 2. Destroying the cache VM before the fleet is redeployed re-creates the stall

Every host still carries `https://cache.homelab.local/homelab` as a substituter
until it is redeployed, and the *target* is what fetches from it during a push.
Point that at a name that resolves to a host which no longer answers and nix
waits on it — `stalled-download-timeout` is 300 s per path, which is how a
19-minute "copying path … from cache.homelab.local" happens.

**Least-surprise order** would have been: fleet apply first (drops the
substituter), *then* destroy the VM. **That is not what happened** — the cache VM
was destroyed on 2026-09-09 while every host still pointed at it.

**`deployment.substituteOnDestination = false` is NOT the fix — that option does
not exist in this colmena.** It was tried in `colmenaHive.defaults` and broke
evaluation of every node (`The option 'deployment.substituteOnDestination' does
not exist`). The valid deployment options are `buildOnTarget`, `sshOptions`,
`targetHost`/`Port`/`User`, `tags`, `keys` and friends — see
`src/nix/hive/options.nix` in the colmena source before reaching for another.

**What actually resolved it:** once `dns` was reinstalled it stopped serving an A
record for `cache.homelab.local`, so lookups now NXDOMAIN immediately rather than
hanging on a dead IP for `stalled-download-timeout` (300 s) per path. The stall
was never really about substitution being enabled — it was about a name that
resolved to an address nothing answered on. A substituter that fails fast is
harmless noise.

To move only the `dns` disk without touching the cache VM:

```bash
cd iac && tofu apply -target=proxmox_virtual_environment_vm.dns_vm
```

---

## Part A — `dns` to `ssd_pool` + XFS

### Live facts (verified 2026-09-09)

| Fact | Value |
| --- | --- |
| Guest | VM **4326**, `homelab-dns`, **192.168.2.145** (static, `ens18`) |
| Disk | single `scsi0` → `/dev/sda`, **20 GB**, **`zfs_pool`** |
| Stable by-id | `scsi-0QEMU_QEMU_HARDDISK_drive-scsi0` — `disko-xfs.nix`'s default pin is correct, no override needed |
| Layout today | 1 M BIOS + 1 G ext4 `/boot` + 15 G **btrfs** (`/root` `/home` `/nix` `/var` + 4 G swapfile subvol) |
| Root usage | **14 G of 15 G — 89 %** |
| `iac/main.tf` said | `size = 16` — **stale**, below the live 20 GB; a plan would have tried to shrink and the provider cannot. Now 32. |
| Memory | `dedicated 1536 / floating 768` — **not pinned** |
| agenix | `tailscale-auth-key`, `fleet-enroll-secret` (via `users`) |
| Tailscale role | **subnet router** — advertises `192.168.2.0/24`, and the tailnet's split-DNS target for `homelab.local` |

### Why the blast radius is smaller than it looks

`modules/dns-client-cache.nix` puts a local unbound stub on **every host except
this one**, with `serve-expired` + `serve-expired-ttl 1800` and a 30-minute
`cache-min-ttl` floor. While `dns` is down, other hosts answer `*.homelab.local`
from stale cache rather than failing, and `modules/common.nix` lists
`192.168.2.1` as a second nameserver for public names. A window well under 30
minutes is absorbed almost invisibly.

What does *not* survive: any name first resolved after a stub's cache ages out,
and any tailnet client reaching the LAN through the subnet route.

### The one trap: RAM vs kexec

`nixos-anywhere` kexecs a NixOS installer into RAM and wants ~1.5 GB. This guest
is `dedicated 1536 / floating 768`, i.e. **unpinned**, on an oversubscribed host
([`pve-gigabyte-memory-oversubscription.md`](./pve-gigabyte-memory-oversubscription.md)),
so the balloon may have taken it under the line. Check before you start.

### A0 · Pre-flight

- [ ] **A0.1 Verify `ssd_pool` has room.** The 888 G mirror held only immich
      (~70 G) when [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md)
      was measured on 2026-08-08; `woodpecker` (100 G) and `k3s-cntrl-1` (64 G)
      landed since, and `cache`'s 200 G is about to come *back* (Part B). Measure
      rather than trust: `zpool list ssd_pool` on `pve-gigabyte`.
- [ ] **A0.2 Confirm the closure is built**, so the install never needs a name
      resolved while the resolver is down (the `homelab-mcp` flake input is
      `git+https://forgejo.homelab.local/…`):
      ```bash
      nix build --no-link --print-out-paths '.#nixosConfigurations.dns.config.system.build.toplevel'
      ```
      Done once on 2026-09-09; re-run after any further edit.
- [ ] **A0.3 Check the guest has its memory** — `ssh amadeus@192.168.2.145 free -m`
      should show MemTotal near 1500, not 768. If low, un-balloon from the PVE
      host: `qm set 4326 --balloon 1536`. **Note `dns` currently has no swap** —
      the swapfile was deleted on 2026-09-09 to break the ENOSPC wedge (see the
      banner at the top), so this check matters more than usual until the
      reinstall restores a real swap partition.
- [ ] **A0.4 Confirm there is room for the kexec.** nixos-anywhere stages a
      ~500 MB installer onto the target's filesystem, so a full disk fails the
      install the same way it failed unbound. After the 2026-09-09 rescue there
      is 4.3 G free; verify with **`btrfs filesystem usage /`**, not `df` —
      `df` reported 1.8 G free while the filesystem was refusing writes.
- [ ] **A0.5 Nothing to back up.** unbound serves a static zone from the Nix
      store, the step-ca cert is re-issued over ACME on first boot, and the
      Tailscale identity is replaced regardless.

### A1 · Move the disk (online, non-destructive)

Do this **before** the reinstall, so XFS lands on the disk in its final home and
the move stays independently revertible.

- [ ] **A1.1 Plan and read it carefully.** `datastore_id` must show as an
      **in-place update** — no `# forces replacement`, `0 to destroy`. Confirmed
      for `woodpecker` on 2026-08-15; verify rather than assume. Note the same
      apply also **destroys the cache VM** (Part B) — expect `1 to destroy` and
      check it is 4340, not something else.
      ```bash
      just iac-plan     # or: cd iac && tofu plan -target=proxmox_virtual_environment_vm.dns_vm
      ```
      The `pg` backend reads `PG_CONN_STR`; without it the plan dies with
      `dial tcp [::1]:5432: connection refused`.
- [ ] **A1.2 Apply.** `just iac-apply`. Proxmox streams the zvol with the guest
      running; 20 GB *off* a ~78 IOPS pool is not instant.
- [ ] **A1.3 Confirm.** `qm config 4326` → `scsi0: ssd_pool:vm-4326-disk-0,discard=on,size=32G`.
      The guest is still btrfs and still sees only 20 GB; A2 repartitions the
      whole disk anyway.

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

### A3 · agenix re-key

New host key ⇒ `age: error: no identity matched any of the recipients`.

- [ ] **A3.1** `just get-host-key 192.168.2.145`, replace `hostDns` in
      `secrets/secrets.nix`.
- [ ] **A3.2** Re-encrypt the affected secrets. ⚠️ **Ask before running
      `just reencrypt`** — amadeus corrected that as the wrong follow-up on
      2026-08-04 and the right procedure was never written down. Targeted form:
      ```bash
      cd secrets
      agenix -e tailscale-auth-key.age -i ~/.config/age/keys.txt   # save unchanged
      agenix -e fleet-enroll-secret.age -i ~/.config/age/keys.txt
      ```
      (`attic-push-token.age` no longer needs re-keying — nothing imports
      `modules/attic-push.nix` since Part B.) Use a **real interactive editor**:
      agenix runs `$EDITOR` with a stripped PATH, and an editor *script* silently
      writes an **empty** secret.
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
      `extraUpFlags` re-advertises it automatically on a fresh install, so this
      is console-side only.
- [ ] **A4.4** Confirm split-DNS still maps `homelab.local` → `192.168.2.145`.
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

## Part B — `cache` decommission

### Why

Measured over 14 days on the live host:

| | count |
| --- | --- |
| Uploads (PUT/POST) | **2,999** |
| NAR fetches | 1,738 — but **1,727 on Sep 08 alone**, 11 on Aug 31, **zero** on the other 12 days |
| Distinct NARs fetched | 256, top ones pulled 38–46× each |

Sep 08 is the day the chunking was retuned 64× in `hosts/cache/attic/default.nix`
— that spike is someone working *on* attic, not benefiting *from* it, and the
repetition looks like retries. Net of it, the cache served **11 organic reads in
two weeks** for ~3,000 uploads.

The reason it stopped paying is structural. `modules/common.nix` imported the
substituter fleet-wide to spare hosts that evaluate the flake locally from
GitHub's 429 rate-limit on input tarballs — and the thing that made every host
evaluate locally was **comin**, retired in `6a387b2`. Everything else deploys via
colmena with `buildOnTarget = false`: the deploy host builds and pushes closures
over SSH, so no target ever consults a substituter. Meanwhile the cost was a VM,
a Postgres database on the **IOPS-starved** `database` host, a push unit firing
on 16 hosts after every activation, 6 secrets, a Caddy vhost, a step-ca cert, two
monitoring targets and a dead Garage module.

`development` and `hermes` do still evaluate the flake locally. If they start
hitting 429s, a GitHub token in `nix.settings.access-tokens` is the direct fix —
not a VM.

### What was unwired in the repo (done)

**The NixOS config was deliberately kept on disk**, wired to nothing, so the
service can be resurrected. Only the VM resource was deleted.

| File | Change |
| --- | --- |
| `iac/main.tf` | `cache_vm` resource + output entry **deleted** (the only deletion) |
| `flake.nix` | 22 `modules/attic-push.nix` imports removed; `cache` commented out of `hostAddrs`, `nixosConfigurations`, `colmenaHive` |
| `modules/common.nix` | fleet-wide `attic-cache.nix` import removed |
| `hosts/development/` | its own `attic-cache.nix` import removed |
| `hosts/database/` | `attic` database, role, password unit and `attic-db-password` secret removed |
| `hosts/dns/` | `cache.homelab.{local,internal}` A records + PTR removed |
| `hosts/otel/configuration.nix` | `cache-node` scrape job removed |
| `hosts/otel/blackbox.nix` | `homelab-cache` cert subjects + `nix-cache-info` probe removed |
| `hosts/containers/homelab-dashboard/` | "Attic Cache" health check removed |
| `justfile` | `attic-init` / `attic-info` / `attic-push` commented out |
| `tests/hosts/database.nix` | `attic` dropped from the db + role assertions |
| **Kept, untouched** | `hosts/cache/**`, `modules/attic-cache.nix`, `modules/attic-push.nix`, `secrets/*.age`, `secrets/secrets.nix` |

`hosts/otel/alerting.nix` needed **no change** — it has no cache-specific rules,
only generic `up`/cert alerts driven by the targets removed above. Deleting the
targets is what silences the alerting.

The nightly `attic` dump also stops **by construction**:
`services.postgresqlBackup.databases` derives from
`config.services.postgresql.ensureDatabases`, so dropping `attic` from that list
drops its backup with it — no second edit, and no stale backup unit left behind.

### Operator steps (done 2026-09-09, except B.5)

- [x] **B.1 Deploy the fleet, minus `dns`.** Every host keeps its
      `attic-login`/`attic-push-system` units and its `cache.homelab.local`
      substituter until redeployed. **Exclude `dns`** — see Ordering hazard 1;
      its config now described a disk it did not have. **Part A is done, so
      `dns` can be included now.**
      ```bash
      just colmena-apply          # all 15 nodes
      ```
      The *push* units failing is harmless (`|| true`). The **substituter** was
      the real hazard, but it has defused itself: the reinstalled `dns` no longer
      serves `cache.homelab.local`, so those lookups NXDOMAIN immediately instead
      of hanging. See Ordering hazard 2.
- [ ] **B.2 Destroy the VM.** Removing the resource from `iac/main.tf` is what
      does it; confirm the plan shows **`1 to destroy`** and that it is VM
      **4340** before applying.
      ```bash
      just iac-plan
      just iac-apply
      ```
      ⚠️ A full `iac-apply` also carries the `dns_vm` disk move (`zfs_pool` →
      `ssd_pool`, 20 → 32 GB). That is fine and desirable — just know both
      changes land in the same apply, and that destroying the cache while the
      fleet still points at it is hazard 2.
- [x] **B.3 Drop the database and role by hand.** ⚠️ `ensureDatabases` only ever
      **creates** — removing `attic` from the list does not drop anything. The
      database, its role and its index will sit on the `database` host until
      dropped explicitly:
      ```bash
      ssh amadeus@192.168.2.134
      sudo -u postgres psql -c 'DROP DATABASE attic;'
      sudo -u postgres psql -c 'DROP ROLE attic;'
      ```
- [x] **B.4 Remove the old dumps.** The nightly job stops on its own, but the
      dumps it already wrote do not:
      `sudo rm -f /var/backup/postgresql/attic.sql*` on the `database` host.
- [ ] **B.5 Check the PBS backup job.** PBS is **not managed by this repo**, so
      nothing above touches it. If its VM-backup job lists **4340**, remove it
      there. (A job listing a guest that no longer exists silently no-ops, the
      same way it does for HA's VM 208 — so this is tidiness, not an outage.)
- [x] **B.6 Delete the `homelab-cache` Tailscale node** at
      <https://login.tailscale.com/admin/machines>.
- [x] **B.7 Confirm the monitoring went quiet.** `homelab-cache` should vanish
      from Prometheus targets and the blackbox probe list, and the dashboard
      should no longer show an "Attic Cache" tile. No alert should fire for the
      disappearance — that is the point of removing the targets rather than
      letting them go red.
- [ ] **B.8 Optional cleanup, deliberately left undone.** `hostCache` is still a
      recipient in `secrets/secrets.nix` (including the `users` list) and the
      5 attic/garage `.age` files are still committed. They are inert — a dead
      recipient costs nothing but a stale entry — and keeping them means a
      revival needs no re-keying. Remove them only if you decide the cache is
      never coming back.

---

## Part C — `ca` to XFS **on `ssd_pool`**

> **Scope changed 2026-09-09.** This section used to read "XFS only, no pool
> move", on the reasoning that `ca` is "a small, low-traffic guest whose problem
> today was btrfs's data/metadata chunk split, not IOPS". **That reasoning was
> wrong, and it was measured wrong.** See C-why below. amadeus approved the pool
> move after seeing the numbers.

### C-why · the measurement that changed the plan

Taken on the live host while it was otherwise idle:

```
20 × 4 KiB O_DSYNC writes   10.04 s   →  ~500 ms/write, ~2 IOPS, 8.2 kB/s
/proc/pressure/io    full   avg10=54  avg60=67  avg300=59    ← no test running
/proc/pressure/cpu   full   avg10=0.00 avg60=0.00 avg300=0.00
load 1.55 on an idle CPU
```

A durable 4 KiB write costs **half a second**. Not the pool's nominal ~78 IOPS —
about **2**. CPU and RAM are untouched; the guest is IO-stalled well over half of
its wall clock at rest.

That is the whole explanation for the `badNonce` storm on `database` earlier the
same evening. ACME anti-replay nonces are single-use by design (RFC 8555 §6.5):
the server *must* reject a stale one and the client retries with a fresh one.
Let's Encrypt emits them constantly and nobody notices, because the retry
succeeds. Here every retry needed another durable write on a 2-IOPS disk, so all
11 attempts missed. step-ca's `badgerv2` store writes **and deletes** a record
per nonce, on top of order/authz/challenge/cert records — it write-amplifies
precisely the workload a CA has. Four concurrent issuances is enough.

Corroborating: in the 2026-09-09 fleet apply, `ca` took **10 minutes** to
activate while SSD-backed `dns` took **16 seconds**.

Two things worth keeping straight:

- **`ca` being "on its own VM" isolates nothing that mattered.** The VM boundary
  gives it its own CPU and RAM — both idle — but its disk is a zvol on the same
  2-HDD mirror as every other guest. The bottleneck is *under* the VM.
- **XFS alone would not have fixed this.** The filesystem swap addresses the
  btrfs ENOSPC failure class (real — `ca` was at 89 % of a 19 G root, the same
  figure `dns` sat at before it wedged). It does nothing for a 500 ms sync write,
  because it is the same spindles. Both changes are needed, which is why this
  section now does both.

Still open, deliberately not done here: **`badgerv2` is a poor default for a
CA.** Its value log is 216 MB for a CA issuing a handful of 30-day certs, so
value-log GC is not keeping up, and that is the same file that needed truncating
on the 2026-09-09 reboot after badger's classic "Truncate Needed". smallstep
steer people to SQL backends now. Moving `db.type` to `postgresql` would remove
badger entirely — but it couples CA issuance to the `database` host, whose *own*
cert comes from this CA, so the bootstrap ordering needs thought first. SSD
first; revisit if badger still misbehaves on fast storage.

### ⚠️ Ordering hazard 3 — the CA is down for the whole reinstall

Unlike `dns` (whose loss stalled deploys) or `cache` (whose loss was harmless),
a `ca` outage means **no host in the fleet can issue or renew a certificate**
for the duration. Existing certs keep working — nothing breaks immediately — but
any Caddy that happens to hit its renewal window during the window fails and
falls into the **6-hour in-process backoff** documented in D.5, which does not
recover when the CA comes back.

So:

- **Check the runway first.** Certs are 720 h (30 days) and Caddy renews at 2/3
  life, i.e. at ~10 days remaining. As of 2026-09-09 22:00 the nearest are
  `loki`/`tempo`/`otel`/`prometheus` at ~15 days — they do not renew for another
  ~5 days. That is the window.
  ```bash
  ssh amadeus@otel.homelab.local \
    'curl -sG http://localhost:9090/api/v1/query \
       --data-urlencode "query=sort((probe_ssl_earliest_cert_expiry - time())/86400)"'
  ```
- **Ignore `ca.homelab.local:8443/health` sitting at ~1 day.** step-ca
  self-issues a 24 h leaf and rotates it. It read 0.90 days five days before the
  incident too. It is not a casualty.
- **Afterwards**, if any host did try to renew mid-window, clear it with the
  D.5 sequence (stop Caddy → restart step-ca → start Caddy — a Caddy restart
  alone does *not* clear a badNonce storm).

### Steps

- [x] **C0 · Back up the CA state.** Done 2026-09-09 22:14, verified:
      - `~/backups/step-ca-state-2026-09-09-2214.tar.gz` (57 M, `gzip -t` clean)
        — full tree including the badger db
      - `~/backups/step-ca-identity-2026-09-09/` — just the irreplaceable part
      Both outside the repo. **Never commit these.**

      The irreplaceable material is **16 KB**, not 239 MB:
      `certs/root_ca.crt` (635 B), `certs/intermediate_ca.crt` (688 B),
      `secrets/root_ca_key` (314 B), `secrets/intermediate_ca_key` (314 B),
      `ca.json` (1697 B). Everything else is the badger database.

      ⚠️ **`/var/lib/step-ca` is a symlink to `private/step-ca`** (systemd
      `DynamicUser`/`StateDirectory`). `tar -C /var/lib step-ca` archives the
      *symlink* and silently produces a 117-byte "backup" that looks like it
      worked. Archive `-C /var/lib/private step-ca` instead, and always list the
      result before trusting it.

      Stop step-ca cleanly before archiving (an ungraceful stop tears badger's
      value log — see C3), and stream it off-host rather than writing to that
      89 %-full disk:
      ```bash
      ssh amadeus@ca.homelab.local '
        sudo systemctl stop step-ca >&2
        sudo tar cz -C /var/lib/private step-ca
        rc=$?; sudo systemctl start step-ca >&2; exit $rc
      ' > ~/backups/step-ca-state-$(date +%F-%H%M).tar.gz
      ```
      Take a **fresh** copy immediately before C2 — the db moves, even if the
      identity never does.
- [x] **C1a · `iac/main.tf`** — `ca_vm` now: `ssd_pool`, **32 GB** (was 20),
      blank disk (no `file_id`), `discard = "on"`, `file_format = "raw"`, plus
      the installer `cdrom` on `ide0` and `boot_order = ["scsi0", "ide0"]`.
      Memory was already raised to `2048/2048`.
- [x] **C1b · Swap the disko import — LAST, not now.**
      `hosts/ca/configuration.nix` still imports `modules/disko-config.nix`
      **on purpose**. Swapping it to `disko-xfs.nix` makes the config describe
      partlabels the live disk does not have (Ordering hazard 1), which poisons
      `ca` for every `colmena apply` until it is reinstalled — exactly the state
      `dns` was stuck in. **Change it immediately before C2.**
- [x] **C2 · Recreate the VM.** ⚠️ This **destroys the existing 20 G disk**;
      the `datastore_id` change forces replacement. Confirm the plan touches
      only `ca_vm` and that C0's backup is verified before applying.
      ```bash
      just iac-plan     # expect ca_vm replaced, nothing else surprising
      just iac-apply
      ```
      The VM comes up blank and boots the ISO. A new MAC is harmless: `ca` uses
      a static IP from its NixOS config, not DHCP.
- [x] **C3 · Reinstall.** `ssh-keygen -R 192.168.2.160`, then — because the ISO
      boots a NixOS installer rather than kexec'ing one:
      ```bash
      just deploy ca 192.168.2.160 --phases disko,install,reboot
      ```
      Confirm afterwards: `findmnt -no FSTYPE,SIZE /` → `xfs`, ~27 G root, and a
      real 4 G swap partition (not a btrfs swapfile).
- [x] **C4 · agenix re-key — BEFORE any attempt to start step-ca.**

      ⚠️ **This is the step whose order was wrong on 2026-09-09.** The runbook
      originally had the state restore first, which cannot work: step-ca takes
      its intermediate password from `config.age.secrets.step-ca-password.path`
      via systemd `LoadCredential`, and a reinstalled host has a **new SSH host
      key**, so agenix decrypts nothing. `/run/agenix/` is empty and the unit
      dies before it ever looks at `/var/lib/step-ca`:
      ```
      step-ca.service: Failed to set up credentials: No such file or directory
      step-ca.service: Main process exited, code=exited, status=243/CREDENTIALS
      ```
      That reads like a broken binary or a missing store path. It is neither —
      it is a missing secret. Re-key first, and the restore becomes trivial.

      Get the new key **without needing to log in** (the old entry in
      `known_hosts` and a refusing SSH agent both get in the way otherwise):
      ```bash
      ssh-keyscan -t ed25519 192.168.2.160
      ```
      Update `hostCa` in `secrets/secrets.nix`, then re-encrypt exactly the
      secrets `ca` consumes — `step-ca-password` (its own), plus
      `tailscale-auth-key` and `fleet-enroll-secret` (via `modules/tailscale.nix`
      and `modules/osquery.nix`):
      ```bash
      cd secrets
      for f in step-ca-password tailscale-auth-key fleet-enroll-secret; do
        EDITOR=: agenix -e $f.age -i ~/.ssh/id_ed25519
      done
      ```
      `attic-push-token.age` still lists `hostCa` but **nothing imports
      `modules/attic-push.nix` any more**, so it is inert — skip it.

      ⚠️ **Both halves of that command are load-bearing** (see
      `agenix-rekey-one-secret`): `EDITOR=:` or agenix skips re-encryption, and
      `-i ~/.ssh/id_ed25519` because `~/.config/age/keys.txt` is the wrong
      identity. **`just reencrypt` is NOT the fix.** Confirm with `sha256sum`
      before/after — unchanged means nothing happened, whatever it printed.

      ⚠️ **Run it in a real terminal.** The key is passphrase-protected, so a
      non-interactive shell fails with `could not read passphrase … /dev/tty is
      not available`. The same missing TTY breaks `git commit` signing
      (`agent refused operation`) and SSH once the gpg-agent cache expires.

      Then push the re-encrypted secrets: `just cah ca`.
- [x] **C5 · Restore the CA state** — safe to do at any point, but it only takes
      effect once C4 has landed.
      ```bash
      scp ~/backups/step-ca-state-<ts>.tar.gz amadeus@192.168.2.160:/tmp/
      ssh amadeus@192.168.2.160 '
        sudo systemctl stop step-ca
        sudo tar xzf /tmp/step-ca-state-<ts>.tar.gz -C /var/lib/private
        sudo chown -R step-ca:step-ca /var/lib/private/step-ca
        sudo systemctl start step-ca'
      ```
      `-C /var/lib/private`, **not** `/var/lib` — see the symlink note in C0.
      Verify, then prove a real issuance rather than trusting a green unit:
      ```bash
      curl -sS -o /dev/null -w '%{http_code}\n' https://ca.homelab.local:8443/health
      ```
      and force a renewal on another host.

      If badger refuses to open —
      `Truncate Needed. File …/db/000000.vlog size: 214233088 Endoffset: 214233040`
      — trim to the `Endoffset` it prints, after copying the db aside:
      ```bash
      sudo truncate -s <Endoffset> /var/lib/private/step-ca/db/000000.vlog
      sudo systemctl reset-failed step-ca && sudo systemctl start step-ca
      ```
      The discarded tail is an uncommitted record, and **the CA identity is not
      in badger** — the certs and keys are plain files — so this never risks the
      root of trust.
- [x] **C6 · Tailscale — fixed declaratively, done 2026-09-09.**

      `ca` came up `Logged out`, and `systemctl restart tailscaled-autoconnect`
      could not fix it:
      ```
      Failed to restart tailscaled-autoconnect.service: Unit agenix.service not found.
      ```
      Two separate faults, both now handled in `modules/tailscale.nix`:

      1. The module carried `requires = ["agenix.service"]`. **agenix runs here
         as a system activation script, not a systemd unit**, so a hard
         `requires` on it made the service permanently unstartable — the
         dependency meant to make autoconnect reliable was what stopped it ever
         running. (`hosts/ca` used `wants` for step-ca, which degrades to a
         no-op when the unit is missing; `requires` hard-fails.) The ordering it
         wanted is free anyway: stage-2 runs activation before systemd.
      2. `tailscaled-autoconnect` is a oneshot, re-run only when its unit file
         changes or on reboot — never merely because the secret changed. On a
         reinstall the host boots *before* its secrets can be re-keyed, finds no
         auth key, gives up, and the deploy that finally delivers the key does
         not re-run it. Hence every reinstall in this lab ending in a manual
         `tailscale up`. Fixed with the repo's `secretNonce` /
         `restartTriggers` idiom (same pattern as `modules/attic-push.nix`):
         bump the nonce when the auth key is re-encrypted and the next deploy
         re-runs the login.

      One `colmena apply --on ca` (23 s total) was all it took:
      `tailscaled-autoconnect` ran with `Result=success` and the host came back
      as `homelab-ca` at `100.117.250.26`, `Online: true`, 22 peers — a full
      netmap, so it is approved.

      **No manual approval or cleanup was needed**, contrary to the expectation
      set by [[reinstalled-host-tailscale-reapproval]]: it reclaimed its
      original name rather than joining as `homelab-ca-1`, so there was no stale
      duplicate to delete. Worth noting that the `-1` suffix is not guaranteed.
- [x] **C7 · Re-measure.** Done 2026-09-09 — the justification for the move:

      | | before (`zfs_pool`, btrfs) | after (`ssd_pool`, XFS) |
      |---|---|---|
      | 20 × 4 KiB `O_DSYNC` | **10.04 s** | **0.033 s** |
      | per write | ~500 ms | ~1.6 ms |
      | throughput | 8.2 kB/s | 2.5 MB/s |
      | effective IOPS | ~2 | ~600 |
      | `io pressure full avg60` | **67** | **0.03** |
      | root | 19 G btrfs @ 89 % | 26.9 G XFS, 10.6 G used |

      **~305× faster on the metric that actually drives badger.** Swap is a real
      4 G partition (`/dev/sda3`), `/boot` is 973 M ext4.

      **CA identity verified preserved** — the test that matters, since a new
      root would silently break fleet-wide trust. From `dns`, against its
      *system* trust store with no `-k`:
      ```
      https://ca.homelab.local:8443/health   HTTP 200
      https://database.homelab.local         HTTP 200
      ```

## Part D — Fold the findings back

- [ ] **D.1** Tick `dns` off Phase 2 in
      [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md), and note that
      `cache`'s 200 G came back to `ssd_pool` rather than being migrated.
- [ ] **D.2** Record the measured `dns` move time and any before/after IOPS —
      that table is the evidence base for moving the remaining root disks.
- [ ] **D.3** Decide whether `dns` gets `floating = dedicated`. Every guest that
      hit balloon starvation here (`harbor`, `forgejo`, `woodpecker`,
      `k3s-cntrl-1`) ended up pinned — but a pinned guest is a balloon
      **non-donor**, so weigh it against
      [`pve-gigabyte-memory-oversubscription.md`](./pve-gigabyte-memory-oversubscription.md).
      Destroying the cache VM gives back 1 GB, which makes this cheaper than it was.
- [ ] **D.4** If the cache is ever revived, revive it *without* Garage — that
      module was `inactive` with 4 KB of data, because atticd used
      `storage.type = "local"`, not S3.
- [ ] **D.5** **A `dns` outage wedges ACME renewal fleet-wide, and it does not
      self-heal.** While `dns` was down (16:05–16:14) every Caddy that happened
      to be inside its renewal window failed with `lookup ca.homelab.local:
      Temporary failure in name resolution` and backed off to
      `"retrying_in": 21600` — a **6-hour, in-process** timer. Fixing DNS does
      not shorten it. `database` was left with `database.homelab.internal` and
      `pgadmin.homelab.internal` at **0.98 days** of validity; the
      `CertificateExpiringSoon` alert (which already says "restart caddy on the
      serving host") is what caught it. `systemctl restart caddy` clears the
      backoff.

      Two things to check before believing this alert next time:

      - **`ca.homelab.local:8443/health` sitting at ~1 day is normal.** step-ca
        self-issues a 24 h leaf and rotates it; it read 0.90 days five days
        earlier too. Do not treat it as a casualty of the outage.
      - The real signal is a host whose *other* certs are at 15–21 days while a
        couple sit near zero — that is the wedge, not a fleet-wide expiry.

      Worth considering: an alert on `caddy` renewal *failures* rather than only
      on the resulting expiry would have caught this at 16:05 instead of at
      0.98 days remaining.

- [x] **D.6 Audit every `requires` on `agenix.service` in this repo.** Done
      2026-09-09 — `modules/tailscale.nix` was the **only** `requires`. The
      other three sites (`hosts/fleet`, `hosts/ca`, `hosts/database`) use
      `after`/`wants`, which systemd ignores harmlessly when the unit is
      absent. No other host was affected.

      Original note: The
      tailscale module's hard dependency on a unit that does not exist (C6) is
      unlikely to be the only one, and the failure mode is nasty: the service
      never runs, and the error names a missing unit rather than the real
      problem. `wants` is the safe form when the target may not exist; better
      still, drop it — activation already precedes systemd at boot.
      ```bash
      grep -rn "agenix.service" --include="*.nix" .
      ```
- [x] **D.7 Make secret-consuming oneshots re-run themselves.** Solved
      2026-09-09 — the answer is a one-line change, not a discipline.

      The problem: a oneshot like `tailscaled-autoconnect` or `attic-login`
      reads its secret through **`config.age.secrets.<n>.path`**, which is
      `/run/agenix/<n>` — **stable forever**. So the generated unit never
      changes when the secret is rotated, NixOS sees no reason to re-run it, and
      the host silently keeps whatever it read at its last activation. That is
      how `ca` sat at `Logged out` after its re-key.

      The fix: trigger on **`.file`** instead, which is the `.age` file's
      **content-addressed store path**:

      ```nix
      restartTriggers = [config.age.secrets.tailscale-auth-key.file];
      ```

      ```
      .path = /run/agenix/tailscale-auth-key             stable  → never re-runs
      .file = /nix/store/<hash>-tailscale-auth-key.age   content → re-runs
      ```

      Verified in the built unit:
      ```
      X-Restart-Triggers=/nix/store/66fhhml6...-X-Restart-Triggers-tailscaled-autoconnect
        contents: /nix/store/lcqmx6r9...-tailscale-auth-key.age
      ```

      **Prefer this over the hand-bumped `secretNonce` string** in
      `modules/attic-push.nix`: a nonce you have to remember to bump fails
      silently, which is exactly the failure it exists to prevent.

      One caveat that decides which to use: age is non-deterministic (fresh
      ephemeral key per encryption), so **even a no-op re-encrypt re-runs the
      unit**. Harmless when the action is idempotent (`tailscale up`,
      `attic login`). If a redundant re-run would be expensive or disruptive,
      keep the manual nonce so the operator picks the moment.

      Still using the old idiom: `modules/attic-push.nix` — but nothing imports
      it any more, so it is dead code rather than a live hazard.
---

## Rollback

- **`dns`, after A1 and before A2:** revert `datastore_id` to `zfs_pool` and
  apply. The guest never stopped; nothing was lost.
- **`dns`, once the reinstall starts:** no rollback, only forward — the disk is
  wiped the moment disko runs. The guest is stateless (A0.4), so a second
  `just deploy dns 192.168.2.145` is a complete fix.
- **If DNS stays down and you need the lab back now:** other hosts survive on
  their `serve-expired` stubs plus the `192.168.2.1` fallback. Colmena targets
  `dns` by raw IP, so you can always redeploy the resolver without the resolver.
- **`cache`, after B.2:** the VM and its 4.1 GB of NAR storage are gone. Reviving
  means uncommenting the flake node, restoring the `iac/main.tf` resource, and
  running `just attic-init` — which the 2026-08-02 notes flag as *written but
  never executed, treat as unverified*. Do **not** revive the Postgres index
  without the storage, or the cache serves narinfos for NARs that no longer
  exist — a lying cache, worse than no cache.
