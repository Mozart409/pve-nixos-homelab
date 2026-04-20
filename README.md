# pve-nixos-homelab

NixOS flakes, Colmena, and OpenTofu definitions for a small Proxmox homelab. Hosts currently managed:

- `database`: PostgreSQL server with exporter and Tailscale
- `otel`: OpenTelemetry Collector with node exporter and OTLP ports open
- `dns`: DNS server
- `unifi`: UniFi Network Controller
- `containers`: Container host
- `mcp`: MCP server (hamcp-rs)
- `k3s-server-1`: K3s Kubernetes server node
- `k3s-agent-1`: K3s Kubernetes agent node
- `ca`: Certificate Authority

## Quick start

### Dev shell

```
nix develop
```

Provides:
- **IaC**: `opentofu`, `tofu-ls`, `colmena`, `nixos-anywhere`, `agenix`
- **Containers**: `podman`, `podman-compose`, `dive`, `lazydocker`
- **Kubernetes**: `timoni`
- **Rust**: `cargo`, `rustc`, `rust-analyzer`, `bacon`, `rainfrog`
- **AI**: `opencode`, `claude-code`
- **Utilities**: `just`, `dprint`, `kics`

### Nix workflows

- Format: `just fmt`
- Check flake & hosts: `just nixos-check`
- Build a host: `just nixos-build-<hostname>`

### Deploy

Initial install to a target IP using nixos-anywhere:

```
just deploy-<hostname> <ip>
```

Colmena apply (after initial install):

```
colmena apply --on <hostname>
```

Use `DEPLOY_NET=tailscale` to deploy via Tailscale hostnames instead of local IPs.

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
