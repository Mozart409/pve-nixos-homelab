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
- ✅ `iac/main.tf` `ca_vm`: stale `size = 16` corrected to the live `20`
- ✅ `cache` decommissioned in the repo — Part B lists exactly what was unwired
- ✅ `dns` closure pre-built on wotan
- ⬜ `hosts/ca/configuration.nix` still on btrfs **deliberately** — see C1

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
- ⬜ Fleet `colmena apply` — `dns` can now be included, Part A is done
- ⬜ Drop the `attic` + `futo_notes` databases on `database` (B.3/B.4)
- ⬜ Part C (`ca` → XFS)

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

### Operator steps (not started)

- [ ] **B.1 Deploy the fleet, minus `dns`.** Every host keeps its
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
- [ ] **B.3 Drop the database and role by hand.** ⚠️ `ensureDatabases` only ever
      **creates** — removing `attic` from the list does not drop anything. The
      database, its role and its index will sit on the `database` host until
      dropped explicitly:
      ```bash
      ssh amadeus@192.168.2.134
      sudo -u postgres psql -c 'DROP DATABASE attic;'
      sudo -u postgres psql -c 'DROP ROLE attic;'
      ```
- [ ] **B.4 Remove the old dumps.** The nightly job stops on its own, but the
      dumps it already wrote do not:
      `sudo rm -f /var/backup/postgresql/attic.sql*` on the `database` host.
- [ ] **B.5 Check the PBS backup job.** PBS is **not managed by this repo**, so
      nothing above touches it. If its VM-backup job lists **4340**, remove it
      there. (A job listing a guest that no longer exists silently no-ops, the
      same way it does for HA's VM 208 — so this is tidiness, not an outage.)
- [ ] **B.6 Delete the `homelab-cache` Tailscale node** at
      <https://login.tailscale.com/admin/machines>.
- [ ] **B.7 Confirm the monitoring went quiet.** `homelab-cache` should vanish
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

## Part C — `ca` to XFS (staying on `zfs_pool`)

`ca` gets the filesystem change **only** — no pool move. It is a small,
low-traffic guest whose problem today was btrfs's data/metadata chunk split, not
IOPS, and `ssd_pool` capacity is better spent elsewhere. So: XFS, still
`zfs_pool`, same 20 GB.

The urgency is gone (the `sfdisk` rescue above bought it 3.5 GiB of unallocated
space and dropped metadata to 61.9 %), so this is planned work, not a fire.

### ⚠️ Do the config swap LAST, not now

`hosts/ca/configuration.nix` still imports `modules/disko-config.nix` **on
purpose**. Swapping it to `disko-xfs.nix` makes the config describe partlabels
the live btrfs disk does not have — Ordering hazard 1 — and `ca` would then be
poisoned for every `colmena apply` until it is reinstalled. That is exactly the
state `dns` is in now, and it is why `dns` has to be excluded from fleet
deploys. **Change the import immediately before C2, not before.**

- [ ] **C0 · Pre-flight**
  - [ ] Confirm the rescue held: `sudo btrfs filesystem usage /` should still
        show ~3.5 GiB unallocated and metadata well under 90 %.
  - [ ] Check RAM against the kexec floor (~1.5 GB). `ca_vm` is
        `dedicated 768 / floating 384` — **well under**, so raise it first:
        `qm set 4337 --memory 2048 --balloon 2048`, or bump `memory` in
        `iac/main.tf` and apply. This is the single most likely thing to fail.
  - [ ] `nix build --no-link '.#nixosConfigurations.ca.config.system.build.toplevel'`
        so the install needs nothing fetched.
  - [ ] Note what is stateful: **step-ca's `/var/lib/step-ca`** — the CA root key,
        intermediate, and its database. Unlike `dns`, this host is **NOT**
        disposable. Losing the CA root means re-issuing trust on every host that
        imports `modules/step-ca-trust.nix`. **Back it up and verify the copy
        before wiping**, and do not rely on the backup landing in `/tmp`.
- [ ] **C1 · Swap the disko import** in `hosts/ca/configuration.nix`:
      `../../modules/disko-config.nix` → `../../modules/disko-xfs.nix`.
      Optionally add `discard = "on"` to the `ca_vm` disk in `iac/main.tf` — the
      XFS module enables a weekly `services.fstrim`, and without `discard` those
      TRIMs never reach ZFS. Leave `datastore_id = "zfs_pool"` alone.
- [ ] **C2 · Reinstall.** `ssh-keygen -R 192.168.2.160`, then
      `just deploy ca 192.168.2.160` (static IP, so the full-config path as in
      A2.2). Confirm afterwards with
      `findmnt -no FSTYPE,SIZE /` → `xfs`, ~15 G root, 4 G swap partition.
- [ ] **C3 · Restore step-ca state**, then verify a real issuance end to end —
      not just that the unit is green.

      ⚠️ **Stop step-ca cleanly before the wipe, and expect to repair its Badger
      DB if you don't.** An ungraceful stop leaves a torn tail in the value log
      and step-ca then refuses to start at all:
      ```
      badger WARNING: Truncate Needed. File …/db/000000.vlog size: 214233088 Endoffset: 214233040
      Error opening database of Type badgerv2: … Value log truncate required to run DB
      ```
      This happened on the 2026-09-09 reboot. The fix is to trim the file to the
      `Endoffset` badger prints (48 bytes there) after backing the DB up:
      ```bash
      sudo systemctl stop step-ca
      sudo cp -a /var/lib/step-ca/db /root/step-ca-db.bak-$(date +%F-%H%M)
      sudo truncate -s <Endoffset> /var/lib/step-ca/db/000000.vlog
      sudo systemctl reset-failed step-ca && sudo systemctl start step-ca
      ```
      The discarded tail is an uncommitted record, and **the CA's key material is
      not in Badger** — `certs/{root,intermediate}_ca.crt` and
      `secrets/{root,intermediate}_ca_key` are plain files, so the CA identity is
      never at risk from this. Back those up separately regardless.

      Then confirm it actually serves:
      ```bash
      curl -sS -o /dev/null -w '%{http_code}\n' https://ca.homelab.local:8443/health
      ```
      and force a cert renewal on some other host to prove ACME still works
      against the restored CA.
- [ ] **C4 · agenix re-key.** New host key ⇒ update `hostCa` in
      `secrets/secrets.nix` and re-encrypt what it consumes (same cautions as
      A3.2 — ask before `just reencrypt`).
- [ ] **C5 · Tailscale.** Delete the stale `homelab-ca` node and approve the new
      one. No subnet route on this host.

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
