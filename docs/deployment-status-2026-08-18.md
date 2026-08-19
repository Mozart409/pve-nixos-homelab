# Deployment Status

Status for the current rollout of the latest NixOS changes on 2026-08-18.

This is the **Comin deployment**. Once Comin is successfully deployed on a VM,
that VM polls the canonical Forgejo Git repository and applies updates from the
`main` branch automatically. Future configuration changes therefore deploy via
Git after they are merged, instead of requiring a manual deployment on every
machine.

## Completed (comin active)

These VMs have been bootstrapped and **`comin.service` is `active`**, polling
Forgejo and auto-deploying from `main`. See `docs/comin-findings-2026-08-18.md`
for details on comin behavior and the harmless `HEAD outside of refs/` warning.

On 2026-08-19, `containers`, `mcp`, `fleet`, `cache`, and `otel` were found
stuck several commits behind: comin evaluates each host's own config **on
that host**, and low free RAM (confirmed on `containers`: 145MB free of
1.6GB, 1.4GB swap in use, journald logging memory-pressure flushes) was
causing comin's on-host evaluation of `main` to fail outright — not a flake
regression (`nix build`/`colmena build` for the same commit succeeded
cleanly from the controller both then and now). This also explained the
attic-push failures below: `cache` itself was one of the stuck hosts, so
pushes to it errored. Fixed same-day by running `colmena apply --on <host>`
for each (`fd6fdf7`), which builds on the controller and only pushes/activates
remotely, sidestepping the target's eval-memory problem. All 5 confirmed
via successful `colmena apply` output; `cache` and `containers` were further
confirmed live via `readlink -f /run/current-system` matching the deployed
store path. `comin status` on both still shows a stale "Evaluation failed"
against `fd6fdf7` from before the fix — that's comin's own bookkeeping,
which a colmena-driven switch bypasses entirely (it doesn't go through
comin's deployer), not evidence anything is currently wrong. `otel`, `mcp`,
and `fleet` weren't independently re-verified this session.

- `otel` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active
- `containers` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active
- `dns` — version `26.11pre-git` (updated 2026-08-18); comin active, evaluating latest commit
- `mcp` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active
- `fleet` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active
- `cache` — updated 2026-08-19 via `colmena apply` (`fd6fdf7`); comin active

`containers` is a VM. The containerized services running on it are covered by
that VM deployment.

## In Progress

- `forgejo`

## Failed

- `hermes`

Investigate the failed `hermes` activation before retrying its deployment.
Comin is not considered active on `hermes` until this bootstrap deployment
succeeds.

## Still To Deploy

- `otel` — comin-agent inactive, needs manual `colmena apply` or service start
- `containers` — comin-agent inactive, needs manual `colmena apply` or service start
- `dns` — comin-agent inactive, needs manual `colmena apply` or service start
- `mcp` — comin-agent inactive, needs manual `colmena apply` or service start
- `fleet` — comin-agent inactive, needs manual `colmena apply` or service start
- `cache` — comin-agent inactive, needs manual `colmena apply` or service start
- `database`
- `unifi`
- `ca`
- `harbor`
- `woodpecker`
- `development`
- `jellyfin`

All entries above are VMs managed by the Colmena hive. `minimal` and `iso` are
installer images, not deployment targets.

## Next: Loki logging rollout (commit `39773f5`)

`39773f5` wires `comin.service` / `attic-login.service` /
`attic-push-system.service` journals into the central Loki via
`modules/comin.nix` and `modules/attic-push.nix` (see
`modules/loki-logs.nix`), so fetch/eval/deploy results and push failures
become queryable centrally instead of needing SSH per host. This touches
every comin host, including several that never ran fluent-bit before
(`otel`, `fleet`, `dns`, `unifi`, `harbor`, `ca`, `development`) — a new
steady-state service on hosts already shown to run low on memory (see
above). `modules/loki-logs.nix` itself warns fluent-bit's YAML plugin
schema is NOT validated at build time, only at runtime.

Don't rely on comin's own poll cycle to roll this out — apply manually in
this order, checking `systemctl status fluent-bit` after each, and once
confirmed once, checking `{job="comin"}` / `{job="attic-push"}` /
`{job="attic-login"}` show up in Loki:

1. `containers` — validation target. Already comin-active/current and
   already runs fluent-bit (axon-gateway logs), so this only adds one
   incremental unit. Also the most memory-constrained host confirmed so
   far (145MB free earlier today) — if it handles the extra unit fine,
   everything else should too.
2. `cache` — validates the `attic-login`/`attic-push` vs. `attic` (the
   atticd server's own job) name split, on the one host running all three.
3. `mcp`, `forgejo` — already comin-active and already running fluent-bit
   for their own services.
4. `otel`, `fleet`, `dns` — comin-active, but first time running
   fluent-bit at all.
5. `database`, `jellyfin`, `woodpecker` — not yet bootstrapped, but
   already import `loki-logs.nix` for their own services, so this only
   bootstraps comin, not fluent-bit.
6. `unifi`, `harbor`, `development` — not yet bootstrapped and never ran
   fluent-bit before; comin and Loki shipping land simultaneously here.
7. `ca` — hold until the SSH banner-exchange hang from 2026-08-19 is
   understood; don't add more load to a host that's already timing out on
   basic connections.
8. `hermes` — separate track. Its original comin bootstrap never
   completed (`comin.service` doesn't exist on the host at all);
   investigate with `colmena apply --on hermes -v` before retrying,
   independent of this logging change.
