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

- `otel` — version `26.11pre-git`; comin active
- `containers` — version `26.11.20260813.0e251e2` (nixpkgs from Aug 13); comin active
- `dns` — version `26.11pre-git` (updated 2026-08-18); comin active, evaluating latest commit
- `mcp` — version `26.11pre-git`; comin active (SSH intermittently unreachable)
- `fleet` — version `26.11.20260813.0e251e2` (nixpkgs from Aug 13); comin active
- `cache` — version `26.11pre-git`; comin active (SSH intermittently unreachable)

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

- `database`
- `unifi`
- `ca`
- `harbor`
- `woodpecker`
- `development`
- `jellyfin`

All entries above are VMs managed by the Colmena hive. `minimal` and `iso` are
installer images, not deployment targets.
