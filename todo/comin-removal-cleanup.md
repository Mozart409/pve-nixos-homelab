# Comin removal: clear `/var/lib/comin` from every host

Comin was removed from the repo on 2026-09-08 (`refactor(flake): remove comin
gitops from every host`). The units disappear as each host is applied, but the
**on-disk state does not** — `/var/lib/comin` is left behind on every host that
ever ran it.

**Status — pending, blocked on rolling the fleet.**

## What is left behind

Per host, roughly:

| Path | What it is |
| --- | --- |
| `/var/lib/comin/repository/` | a full git clone of this repo |
| `/var/lib/comin/store.json` | comin's deployment history |
| `/var/lib/comin/gcroots/` | **GC roots pinning old system closures** |
| `/var/lib/comin/grpc.sock` | dead socket |

`gcroots` is the one that actually costs something: it pins closures against
`nix-collect-garbage`, so leaving it in place keeps dead generations on disk on
hosts that are already short on IOPS and space.

## Why it is not done yet

The state must only be cleared **after** a host has been applied without comin —
otherwise a still-running comin recreates it. So this is per-host, and follows
the rollout rather than leading it.

## Steps, per host

```sh
# 1. confirm comin is actually gone on that host
systemctl status comin        # expect: Unit comin.service could not be found
ls /nix/var/nix/gcroots/      # sanity check before touching anything

# 2. move aside (reversible) rather than delete outright
sudo mv /var/lib/comin /var/lib/comin.removed

# 3. after a few days with nothing missed, drop it and reclaim the closures
sudo rm -rf /var/lib/comin.removed
sudo nix-collect-garbage -d
```

Hosts to do: `ca cache containers database development dns fleet forgejo harbor
hermes jellyfin mcp otel unifi woodpecker` — i.e. every colmena node except
`k3s-cntrl-1` (never deployed).

## Verify

- `systemctl status comin` reports the unit does not exist
- `ls /var/lib | grep comin` returns nothing
- `nix-collect-garbage -d` actually frees space on hosts that had many pinned
  generations

## Related

- `todo/comin-gitops.md` — the original plan that introduced comin. Kept for the
  history of *why* it was adopted; superseded by the removal.
- Removal reason: comin refuses to deploy across a rewritten branch
  (`this branch has been hard reset: its head '...' is not on top of '...'`) and
  fails silently at info level, which left otel deploying nothing for three
  weeks while `comin.service` looked healthy.
