# Move `dns` to `ssd_pool` and swap btrfs for XFS

Relocate the `dns` guest's root disk from the 2-HDD `zfs_pool` to `ssd_pool`, and
replace its btrfs root with the XFS layout every new VM here already uses
(`modules/disko-xfs.nix`). Phase 2 of
[`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md), applied to the one
guest the whole lab blocks on.

**The two halves are not equally cheap.** Moving the disk is an online, in-place
`move-disk` the bpg provider does for you. Changing the *filesystem* is a
**full reinstall** — disko only ever runs under nixos-anywhere, never during
`colmena apply` — so this wipes and rebuilds the resolver every other host and
every deploy resolves through.

## Status — repo changes landed, migration not started (2026-09-09)

- ✅ `hosts/dns/configuration.nix` imports `modules/disko-xfs.nix`
- ✅ `iac/main.tf` `dns_vm`: `ssd_pool`, 32 GB, `discard = "on"`
- ✅ closure pre-built on wotan (so the install needs no DNS of its own)
- ⬜ everything below

## Live facts (verified 2026-09-09)

| Fact | Value |
| --- | --- |
| Guest | VM **4326**, `homelab-dns`, **192.168.2.145** (static, `ens18`) |
| Disk | single `scsi0` → `/dev/sda`, **20 GB**, `zfs_pool` |
| Stable by-id | `scsi-0QEMU_QEMU_HARDDISK_drive-scsi0` (present; `disko-xfs.nix`'s default pin is correct, no override needed) |
| Layout today | 1 M BIOS + 1 G ext4 `/boot` + 15 G **btrfs** (`/root` `/home` `/nix` `/var` + 4 G swapfile subvol) |
| Root usage | **14 G of 15 G — 89 %** |
| `iac/main.tf` said | `size = 16` — **stale**, below the live 20 GB; a plan would have tried to shrink and the provider cannot |
| Memory | `dedicated = 1536`, `floating = 768` (**not** pinned) |
| agenix secrets | `tailscale-auth-key.age`, `fleet-enroll-secret.age` (both via `users`), `attic-push-token.age` (explicit `hostDns`) |
| `hostDns` recipient | `ssh-ed25519 AAAA…Oalfc3 root@homelab-dns` (`secrets/secrets.nix:13`) |
| Tailscale role | **subnet router** — advertises `192.168.2.0/24`, and the tailnet's split-DNS target for `homelab.local` |

### Why the blast radius is smaller than it looks

`modules/dns-client-cache.nix` puts a local unbound stub on **every host except
this one**, with `serve-expired` + `serve-expired-ttl 1800` and a 30-minute
`cache-min-ttl` floor. While `dns` is down, other hosts keep answering
`*.homelab.local` from their stale cache rather than failing outright, and
`modules/common.nix` lists `192.168.2.1` as a second nameserver for public names.
A reinstall window of well under 30 minutes is absorbed almost invisibly.

What does **not** survive the window: anything that first resolves a homelab name
after its stub's cache has aged out, and any tailnet client reaching the LAN
through this node's subnet route.

### Why the format change costs a reinstall

`disko` runs exactly once, during `nixos-anywhere`. Editing the disko module and
running `colmena apply` is a **no-op for disks** — the generated mounts key off
`/dev/disk/by-partlabel/*`, so the guest keeps its btrfs root and nothing tells
you otherwise. There is no in-place btrfs→XFS conversion; the only path is wipe
and reinstall.

---

## Phase 0 — Pre-flight (nothing destructive)

- [ ] **0.1 Verify `ssd_pool` has room.** The 888 G mirror held only immich
      (~70 G) when [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md)
      was measured on 2026-08-08; `woodpecker` (100 G), `cache` (200 G) and
      `k3s-cntrl-1` (64 G) have landed since, so re-measure rather than trust
      that number. On `pve-gigabyte`: `zpool list ssd_pool` and `zfs list -t volume`.
      32 G thin is small, but confirm it before the apply.
- [ ] **0.2 Confirm the closure is built** on the machine you deploy from, so the
      install never needs a name resolved while the resolver is down (the
      `homelab-mcp` flake input is `git+https://forgejo.homelab.local/…`):
      ```bash
      nix build --no-link --print-out-paths '.#nixosConfigurations.dns.config.system.build.toplevel'
      ```
      Already done once on 2026-09-09; re-run after any further edit. It must
      print a store path without touching the network.
- [ ] **0.3 Check the guest actually has its memory.** nixos-anywhere kexecs a
      NixOS installer into RAM and wants ~1.5 GB. This guest is `dedicated 1536 /
      floating 768`, i.e. **unpinned**, and `pve-gigabyte` is oversubscribed
      ([`pve-gigabyte-memory-oversubscription.md`](./pve-gigabyte-memory-oversubscription.md)),
      so the balloon may well have taken it below the line:
      ```bash
      ssh amadeus@192.168.2.145 free -m          # MemTotal near 1500, not 768
      ```
      If it is low, un-balloon it for the duration from the PVE host:
      `qm set 4326 --balloon 1536` (revert after, or leave it — every other
      guest that hit balloon starvation here ended up pinned).
- [ ] **0.4 Nothing to back up.** This guest is stateless by design: unbound
      serves a static zone from the Nix store, its step-ca cert is re-issued over
      ACME on first boot, and the Tailscale identity is replaced regardless. No
      `/var/lib` data is worth preserving. Confirm you agree before wiping.

## Phase 1 — Move the disk (online, non-destructive)

Do this **before** the reinstall so nixos-anywhere lays XFS down on the disk in
its final home, and so the move can be reverted independently if it misbehaves.

- [ ] **1.1 Plan and read it carefully.** `datastore_id` must show as an
      **in-place update** — no `# forces replacement`, `0 to destroy`. This was
      confirmed for `woodpecker` on 2026-08-15; verify it again rather than
      assume. The `size` 16 → 32 is a grow, also in place.
      ```bash
      just iac-plan          # or: cd iac && tofu plan -target=proxmox_virtual_environment_vm.dns_vm
      ```
      The `pg` backend takes its connection string from `PG_CONN_STR`; set it in
      the shell or the plan dies with `dial tcp [::1]:5432: connection refused`.
- [ ] **1.2 Apply.** `just iac-apply`. Proxmox streams the zvol to `ssd_pool`
      with the guest running; 20 GB off a ~78 IOPS pool is not instant.
- [ ] **1.3 Confirm.** `qm config 4326` shows `scsi0: ssd_pool:vm-4326-disk-0,discard=on,size=32G`.
      The guest is still btrfs at this point and still only *sees* 20 GB — the
      partition table is not grown, and it does not matter, because Phase 2
      repartitions the whole disk.

## Phase 2 — Reinstall onto XFS (destructive)

**This is the outage.** From here until Phase 3 finishes, `dns` answers nothing.

- [ ] **2.1 Drop the old host key from `known_hosts`** — the reinstall generates
      a new one and both nixos-anywhere and colmena will otherwise refuse:
      ```bash
      ssh-keygen -R 192.168.2.145
      ```
- [ ] **2.2 Reinstall the full config.** Not `deploy-minimal` + colmena: this
      host has a static IP, and `minimal` is DHCP + a different disk layout
      (AGENTS.md §6, "Hosts With Extra Disks / a Static IP").
      ```bash
      just deploy dns 192.168.2.145     # type `dns` at the guard prompt
      ```
      This kexecs, repartitions to 1 M BIOS + 1 G `/boot` + 4 G swap + XFS root,
      installs, and reboots onto the static IP from `hosts/dns/configuration.nix`.
- [ ] **2.3 Confirm the format actually changed** — the whole point of the
      exercise, and the one thing a green deploy does not prove:
      ```bash
      ssh amadeus@192.168.2.145 'findmnt -no FSTYPE,SIZE /; lsblk -o NAME,SIZE,FSTYPE'
      # expect: xfs, ~27G root, 4G swap partition
      ```
- [ ] **2.4 Confirm unbound is answering** before touching anything else:
      ```bash
      dig +short @192.168.2.145 forgejo.homelab.local     # 192.168.2.178
      dig +short @192.168.2.145 nixos.org                 # recursion/forwarding works
      ```
      LAN DNS is restored at this point; the remaining phases are the follow-ups
      a reinstall always drags behind it.

## Phase 3 — agenix re-key (the host key changed)

A reinstalled host authenticates with a **brand-new SSH host key**, so all three
secrets above fail to decrypt and their consumers do not start —
`age: error: no identity matched any of the recipients`.

- [ ] **3.1 Grab the new key** and replace the `hostDns` line in
      `secrets/secrets.nix:13`:
      ```bash
      just get-host-key 192.168.2.145
      ```
- [ ] **3.2 Re-encrypt the three affected secrets.** ⚠️ **Ask before running
      `just reencrypt`** — amadeus corrected that as the wrong follow-up on
      2026-08-04, and the right procedure was never written down. The targeted
      form re-encrypts one file to its current recipients without touching the
      other ~40:
      ```bash
      cd secrets
      agenix -e tailscale-auth-key.age -i ~/.config/age/keys.txt   # save unchanged
      agenix -e fleet-enroll-secret.age -i ~/.config/age/keys.txt
      agenix -e attic-push-token.age -i ~/.config/age/keys.txt
      ```
      Use a **real interactive editor**, not an editor script: agenix runs
      `$EDITOR` with a stripped PATH, and a script that shells out to coreutils
      silently writes an **empty** secret.
- [ ] **3.3 Apply.** `just colmena-apply-host dns` — targets the raw IP from
      `hostAddrs`, so it works whether or not DNS is healthy.
- [ ] **3.4 Verify the secrets landed:**
      ```bash
      ssh amadeus@192.168.2.145 'sudo ls -l /run/agenix/'
      ssh amadeus@192.168.2.145 'systemctl is-active tailscaled osqueryd'
      ```

## Phase 4 — Tailscale: re-approve the node *and its subnet route*

This matters far more here than on an ordinary host. The reinstalled guest joins
as a **new, unapproved node** — usually renamed `homelab-dns-1` because the old
node still holds the base name — and an unapproved node has no netmap.

**This node is the tailnet's subnet router for `192.168.2.0/24`.** Until the
route is re-approved, remote tailnet clients lose the entire homelab LAN, not
just this host.

- [ ] **4.1** Delete the stale `homelab-dns` node at
      <https://login.tailscale.com/admin/machines> so the new one takes the base
      name back.
- [ ] **4.2** Approve the new node.
- [ ] **4.3** Approve the **subnet route** `192.168.2.0/24` on it — a separate
      toggle from node approval, and the one that silently breaks remote access.
      `services.tailscale.extraUpFlags` re-advertises it automatically on a fresh
      install (`tailscaled-autoconnect` does run `tailscale up` when the node is
      not already connected), so this is console-side only.
- [ ] **4.4** Confirm the tailnet split-DNS entry still maps `homelab.local` →
      `192.168.2.145`. It is a LAN IP and did not change, but check it while you
      are in the console.
- [ ] **4.5** Verify from a remote tailnet client:
      ```bash
      dig +short @192.168.2.145 forgejo.homelab.local
      ping 192.168.2.178                      # LAN reachable through the route
      ```

## Phase 5 — Certificates and smoke test

- [ ] **5.1 step-ca cert for `dns.homelab.local`.** Caddy re-requests it over
      ACME on first boot. If it is stuck at HTTP 000, this is the `badNonce`
      storm: stop Caddy → restart step-ca on `ca` → start Caddy, **in that
      order** (either alone fails).
      ```bash
      curl -sS -o /dev/null -w '%{http_code}\n' https://dns.homelab.local
      ```
- [ ] **5.2 Tailscale cert** for `homelab-dns.dropbear-butterfly.ts.net` — needs
      Phase 4 done first (`get_certificate tailscale` fails on an unapproved node).
- [ ] **5.3 Prometheus.** The `dns-node` job is deliberately the one target kept
      on a **raw IP** so the resolver stays observable when unbound is down —
      nothing to change, but confirm the target is `UP` again in
      `hosts/otel/configuration.nix`'s scrape list.
- [ ] **5.4 Fleet/osquery** re-enrolls with the new host identity; confirm the
      host appears in Fleet rather than lingering as a duplicate.
- [ ] **5.5 Lab-wide smoke test.** The dashboard `health_checks` URLs are a
      ready-made set: `200`, `302` and `406` are all healthy, `000` is down.

## Phase 6 — Fold the findings back

- [ ] **6.1** Tick Phase 2 progress in
      [`ssd-tier-for-vm-storage.md`](./ssd-tier-for-vm-storage.md) — `dns` is one
      of the 18 VM root disks that phase is about.
- [ ] **6.2** Record the measured move time and the before/after IOPS if you
      grab them; that table is the evidence base for moving the rest.
- [ ] **6.3** Decide whether to pin `floating = dedicated` on this guest. Every
      other guest that hit balloon starvation here (`harbor`, `forgejo`,
      `woodpecker`, `k3s-cntrl-1`) ended up pinned, and this one is the resolver
      — but a pinned guest is a balloon **non-donor**, so weigh it against
      [`pve-gigabyte-memory-oversubscription.md`](./pve-gigabyte-memory-oversubscription.md)
      rather than doing it reflexively.

---

## Rollback

- **After Phase 1, before Phase 2:** revert `datastore_id` to `zfs_pool` in
  `iac/main.tf` and apply. The guest never stopped running; nothing was lost.
- **After Phase 2 starts:** there is no rollback, only forward. The disk is
  wiped the moment disko runs. Recovery is the same command again — the guest is
  stateless (Phase 0.4), so a second `just deploy dns 192.168.2.145` is a
  complete fix for a failed install.
- **If DNS stays down and you need the lab back now:** other hosts survive on
  their `serve-expired` stubs and the `192.168.2.1` fallback for public names.
  Colmena targets `dns` by raw IP, so you can always redeploy the resolver
  without the resolver.
