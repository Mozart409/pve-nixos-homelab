# pve-nixos-homelab

NixOS flakes, Colmena, and OpenTofu definitions for a Proxmox homelab.

## Hosts

| Host | IP | Role |
|------|------|------|
| `database` | 192.168.2.134 | PostgreSQL 18 + pgbouncer, multi-tenant (terraform, forgejo, buildbot, appdb) |
| `otel` | 192.168.2.135 | OpenTelemetry Collector, Loki, Tempo, Prometheus, Grafana |
| `unifi` | 192.168.2.142 | UniFi Network Controller |
| `dns` | 192.168.2.145 | Unbound recursive DNS + local zone (`homelab.local`) |
| `containers` | 192.168.2.149 | Podman host (Open WebUI, Uptime Forge) |
| `mcp` | 192.168.2.152 | MCP server (hamcp-rs) |
| `hermes` | 192.168.2.155 | Hermes AI agent VM (Open WebUI backend, code agent) |
| `k3s-agent-1` | 192.168.2.156 | K3s Kubernetes agent node |
| `ca` | 192.168.2.160 | step-ca internal Certificate Authority |
| `fleet` | 192.168.2.164 | Fleet osquery management server |
| `k3s-server-1` | 192.168.2.165 | K3s Kubernetes server node |
| `harbor` | 192.168.2.166 | Harbor container registry |
| `rpi4-1` | 192.168.2.170 | Raspberry Pi 4 (edge/gateway) |
| `cache` | 192.168.2.175 | Garage S3 + Attic Nix binary cache |
| `development` | 192.168.2.182 | Isolated dev/test development VM |
| `buildbot-master` | 192.168.2.177 | Buildbot CI scheduler + web UI |
| `forgejo` | 192.168.2.178 | Forgejo git forge (PostgreSQL backend) |
| `buildbot-worker-1` | 192.168.2.179 | Buildbot worker (Nix builds) |
| `jellyfin` | 192.168.2.180 | Jellyfin media server + SSO-Auth |

All hosts expose Caddy-fronted services with both Tailscale TLS and step-ca certificates for `*.homelab.local`.

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
- **Utilities**: `just`, `dprint`, `kics`, `keep-sorted`, `lefthook`

### Nix workflows

- Format: `just fmt`
- Check flake & hosts: `just nixos-check`
- Dry build a host: `just nixos-test <host>`
- Colmena diff: `just colmena-diff` or `just colmena-diff-host <host>`

### Deploy

Initial install to a target IP using nixos-anywhere:

```
just deploy <hostname> <ip>
```

Push updates with Colmena (after initial install):

```
just colmena-apply-host <hostname>
```

Use `DEPLOY_NET=tailscale` to deploy via Tailscale hostnames instead of local IPs.

### Secrets (agenix)

Secrets live in `secrets/*.age`, with recipients declared in `secrets/secrets.nix`.

- Edit a secret: `cd secrets && agenix -e <name>.age`
- Reencrypt after changing recipients: `just reencrypt`

A user-level age identity at `~/.config/age/keys.txt` is registered as a recipient so reencryption is passphrase-free.

### IaC (OpenTofu)

Inside `iac/` (via dev shell):

```
just iac-plan
just iac-apply
```

VM definitions live in `iac/main.tf`. Backend uses PostgreSQL on the `database` host.

## CI

- **Forgejo**: hosts the repo at `https://homelab-forgejo.dropbear-butterfly.ts.net/`
- **Buildbot master**: polls Forgejo every 2 minutes, schedules `nix flake check` on every branch
- **Buildbot worker 1**: executes the Nix builds

Buildbot UI: `https://homelab-buildbot-master.dropbear-butterfly.ts.net/`

## Layout

- `flake.nix` – inputs, NixOS configs, Colmena hive
- `hosts/` – per-host configurations
- `modules/` – shared NixOS modules (common, disko, tailscale, step-ca-trust, osquery, podman)
- `secrets/` – agenix-encrypted secrets + `secrets.nix` recipient map
- `iac/` – Proxmox VM definitions (OpenTofu)
- `justfile` – task runner commands
- `AGENTS.md` – conventions for AI agents working in this repo

## Notes

- Keep plaintext secrets out of the repo: `terraform.tfvars` for IaC credentials, agenix for everything else.
- Always run `just fmt` before committing Nix changes (lefthook hook enforces this).
- New hosts require updates in `flake.nix` (hostAddrs, nixosConfigurations, colmenaHive), `iac/main.tf`, `hosts/dns/configuration.nix` (DNS + PTR), `hosts/otel/configuration.nix` (Prometheus scrape).
