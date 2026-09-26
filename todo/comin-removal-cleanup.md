# Comin removal: clear `/var/lib/comin` from every host

Comin was removed from the repo on 2026-09-08 (`refactor(flake): remove comin
gitops from every host`). The units disappear as each host is applied, but the
**on-disk state does not** — `/var/lib/comin` is left behind on every host that
ever ran it.

**Status — complete 2026-09-13.**

- `/var/lib/comin.removed` deleted on all 8 moved hosts: `containers database
  development forgejo jellyfin mcp otel unifi`. `nix-collect-garbage -d`
  returned 0 freed on spot-checks; the weekly `nix.gc` module (`modules/nix-gc.nix`)
  and pressure-triggered GC (`min-free` / `max-free`) already handle ongoing
  cleanup.
- Already clean: `ca dns`.
- Unreachable + **decommissioned** (VMs no longer exist): `fleet harbor hermes
  woodpecker`.
- `cache`: VM decommissioned 2026-09-09.

**Follow-up 2026-09-27 — the step the first pass missed.** comin also left a
system profile, `/nix/var/nix/profiles/system-profiles/comin` (one generation,
so it is also that profile's *current* one). `nix-collect-garbage -d` never
deletes a profile's current generation, so it stayed a GC root pinning a whole
August closure — that is why every spot-check above freed 0. Measured before
removal (closure-only NAR size, i.e. pre-dedupe/compression): otel 11.1 GiB,
containers 13.7, jellyfin 9.9, unifi 10.3. Found when otel sat at 86% with
only ~5 real generations.

Removed (`rm /nix/var/nix/profiles/system-profiles/comin*` then
`systemctl start nix-gc`) on `containers development jellyfin otel unifi`;
`database forgejo mcp ca dns` had none. GRUB still lists a "Profile 'comin'"
entry on those hosts until their next `colmena apply` regenerates the menu —
harmless, just don't pick it.

## Archive

The steps that were executed, per host:

```sh
systemctl status comin                    # confirmed gone
sudo mv /var/lib/comin /var/lib/comin.removed  # reversible, waited a few days
sudo rm -rf /var/lib/comin.removed        # confirmed nothing broke
sudo nix-collect-garbage -d               # 0 freed on spot-checks (GC module
                                          # already handles ongoing cleanup)
```

Hosts: every colmena node except `k3s-cntrl-1` (never deployed) — see the
status section above for the per-host outcome.

## Verify

- `systemctl status comin` reports the unit does not exist
- `ls /var/lib | grep comin` returns nothing
- `ls /nix/var/nix/profiles/system-profiles/` has no `comin*`
- `nix-collect-garbage -d` actually frees space on hosts that had many pinned
  generations

## Related

- `todo/comin-gitops.md` — the original plan that introduced comin. Kept for the
  history of *why* it was adopted; superseded by the removal.
- Removal reason: comin refuses to deploy across a rewritten branch
  (`this branch has been hard reset: its head '...' is not on top of '...'`) and
  fails silently at info level, which left otel deploying nothing for three
  weeks while `comin.service` looked healthy.
