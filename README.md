# pve-nixos-homelab

NixOS flakes, Colmena, and OpenTofu definitions for a small Proxmox homelab. Hosts currently managed:

- `database`: PostgreSQL server with exporter and Tailscale
- `otel`: OpenTelemetry Collector with node exporter and OTLP ports open

## Quick start

### Dev shell

```
nix develop
```

Provides `just`, `tofu`/`opentofu`, `colmena`, `nixos-anywhere`, and formatting tools.

### Nix workflows

- Format: `just fmt`
- Check flake & hosts: `just nixos-check`
- Build otel: `just nixos-build-otel`

### Deploy

Initial install to a target IP using nixos-anywhere:

```
just deploy-otel <ip>
```

Colmena apply (after initial install):

```
colmena apply --on otel
```

### IaC (OpenTofu)

Inside `iac/` (via dev shell):

```
tofu init
tofu plan
tofu apply
```

## Layout

- `flake.nix` – inputs, NixOS configs, Colmena hive
- `hosts/` – per-host configurations
- `modules/` – shared NixOS modules (common, disko, tailscale)
- `iac/` – Proxmox VM definitions (OpenTofu)
- `justfile` – task runner commands

## Notes

- Keep secrets out of the repo; use `terraform.tfvars` for IaC credentials and age secrets for Nix where applicable.
- Always run `just fmt` before committing Nix changes.
