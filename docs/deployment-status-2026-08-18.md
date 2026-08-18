# Deployment Status

Status for the current rollout of the latest NixOS changes on 2026-08-18.

This is the **Comin deployment**. Once Comin is successfully deployed on a VM,
that VM polls the canonical Forgejo Git repository and applies updates from the
`main` branch automatically. Future configuration changes therefore deploy via
Git after they are merged, instead of requiring a manual deployment on every
machine.

## Completed

These VMs have been deployed successfully:

- `otel`
- `containers`
- `dns`
- `mcp`

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
- `fleet`
- `harbor`
- `cache`
- `woodpecker`
- `development`
- `jellyfin`

All entries above are VMs managed by the Colmena hive. `minimal` and `iso` are
installer images, not deployment targets.
