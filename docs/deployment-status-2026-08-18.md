# Deployment Status

Status for the current rollout of the latest NixOS changes on 2026-08-18.

This is the **Comin deployment**. Once Comin is successfully deployed on a VM,
that VM polls the canonical Forgejo Git repository and applies updates from the
`main` branch automatically. Future configuration changes therefore deploy via
Git after they are merged, instead of requiring a manual deployment on every
machine.

## Completed (bootstrap deployed — comin-agent not yet active)

These VMs have been bootstrapped, but **`comin-agent` is `inactive` on all six**,
so none are auto-updating. Future changes require a manual `colmena apply`.

- `otel` — version `26.11pre-git`
- `containers` — version `26.11.20260813.0e251e2` (nixpkgs from Aug 13)
- `dns` — version `26.11pre-git` (updated 2026-08-18)
- `mcp` — version `26.11pre-git`
- `fleet` — version `26.11.20260813.0e251e2` (nixpkgs from Aug 13)
- `cache` — version `26.11pre-git`

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
