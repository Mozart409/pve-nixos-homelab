# Agent Guidelines for pve-nixos-homelab

This repository contains the NixOS configurations and Infrastructure as Code (OpenTofu) for a Proxmox-based homelab. It currently manages the `database` and `otel` hosts using Nix Flakes, Colmena, and Disko.

## 1. Build, Lint, and Test Commands

The project uses `just` as a command runner. Always prefer `just` commands over raw `nix` or `colmena` commands when available.

### Core Commands
- **Check Configuration**: `just nixos-check`
  - Runs `nix flake check` to verify the validity of all configurations.
- **Format Code**: `just fmt`
  - Uses `alejandra` to format Nix files.
  - Ensure all Nix files are formatted before committing.

### Building
- **Build All Hosts**: `just nixos-build-all`
- **Build otel**: `just nixos-build-otel`
- **Colmena Build**: `just colmena-build` or `just colmena-build-host <host>`
  - Builds configurations using Colmena (useful for deployment checks).

### Testing & Verification
- **Dry Run**: `just nixos-test <host>`
  - Performs a dry-run build for a specific host.
  - Example: `just nixos-test ferron`
- **Colmena Diff**: `just colmena-diff` or `just colmena-diff-host <host>`
  - Shows what changes would be applied to the running systems.

- **Initial Install**: `just deploy-<host> <ip>`
  - Uses `nixos-anywhere` to install NixOS on a fresh machine.
  - Example: `just deploy-otel 192.168.2.134`
- **Update/Apply**: `just colmena-apply` or `just colmena-apply-host <host>`
  - Uses `colmena` to push updates to running hosts.

### Infrastructure as Code (OpenTofu)
The `iac/` directory contains OpenTofu configurations for provisioning Proxmox VMs.
- **Initialize**: `tofu init` (inside `iac/` directory)
- **Plan**: `tofu plan`
- **Apply**: `tofu apply`
- **Format**: `tofu fmt` (run via `nix develop -c tofu fmt` to ensure the tool is available)

## 2. Code Style & Conventions

### Nix / NixOS
- **Formatting**: Strict adherence to `alejandra`. Run `just fmt` to ensure compliance.
- **Structure**:
  - `flake.nix`: Entry point. Defines inputs, outputs, and host configurations.
  - `hosts/<hostname>/`: Contains host-specific configurations (`configuration.nix`).
  - `modules/`: Shared NixOS modules (if any).
- **Naming**:
  - Use `camelCase` for variable names and attributes.
  - Hostnames are lowercase (e.g., `ferron`, `caddy`).
- **Imports**:
  - Use relative paths for local imports (e.g., `./hardware-configuration.nix`).
  - Prefer importing modules from `inputs` where applicable.
- **Flake Inputs**:
  - `nixpkgs`: Follows `nixos-unstable`.
  - `disko`: Used for disk partitioning.
  - `colmena`: Used for deployment.

### OpenTofu (IaC)
- **Directory**: `iac/`
- **Formatting**: Use `tofu fmt` to maintain standard HCL formatting.
- **Naming**:
  - Resources: `snake_case` (e.g., `proxmox_virtual_environment_vm`).
  - Variables: Descriptive `snake_case` names (e.g., `proxmox_api_token`).
- **Providers**:
  - Uses `bpg/proxmox` provider.
- **Resources**:
  - `proxmox_virtual_environment_vm` for VMs.
  - `proxmox_virtual_environment_download_file` for downloading ISOs/images.
- **Best Practices**:
  - Use `variables` for sensitive data or reusable values.
  - Keep `main.tf` clean; split into `variables.tf` or `providers.tf` if it grows too large (currently unified in `main.tf`).

### General Development
- **Dev Environment**:
  - Use `nix develop` (or the automatic direnv integration if available) to enter the development shell.
  - The shell provides: `just`, `kics`, `tofu-ls`, `opentofu`, `rust-analyzer`, etc.
- **Secrets**:
  - **NEVER** commit secrets to the repository.
  - Use `terraform.tfvars` (ignored by git) for IaC secrets.
  - Use `sops-nix` or similar (if configured) for NixOS secrets (not currently seen, but standard practice).

## 3. Workflow for Agents

1.  **Exploration**:
    -   Read `flake.nix` to understand the current inputs and host definitions.
    -   Read `justfile` to understand available task runners.
    -   Check `hosts/` for existing host configurations.
    -   If `context7` or `grep` MCP servers are available, use them for documentation and code search.

2.  **Making Changes**:
    -   **NixOS**: Edit `hosts/<host>/configuration.nix` or associated files.
        -   Verify syntax with `just nixos-check`.
        -   Format with `just fmt`.
    -   **IaC**: Edit `iac/main.tf`.
        -   Verify with `tofu validate` (if inside `iac/`).

3.  **Verification**:
    -   Always run `just nixos-check` after modifying Nix files.
    -   If modifying `flake.nix`, ensure `nix flake check` passes.
    -   For extensive changes, try a dry-run build (`just nixos-test <host>`).

4.  **Formatting**:
    -   Always run `just fmt` before finishing a task involving Nix files.

## 4. Key Technologies
-   **NixOS**: Operating System.
-   **Flakes**: Project structure and dependency management.
-   **Colmena**: Deployment tool (push-based).
-   **NixOS-Anywhere**: Initial installation tool.
-   **Disko**: Declarative disk partitioning.
-   **OpenTofu**: Infrastructure provisioning (fork of Terraform).
-   **Proxmox**: Virtualization platform target.

## 5. Adding New Hosts Checklist

When adding a new host to the homelab, ensure the following are updated:

1. **Host Configuration**: Create `hosts/<hostname>/configuration.nix`
2. **Flake Registration**:
   - Add to `hostAddrs` with local IP and Tailscale name
   - Add to `nixosConfigurations` using `mkHost`
   - Add to `colmenaHive` with deployment settings
3. **Infrastructure (OpenTofu)**: Add VM resource in `iac/main.tf` and update outputs
4. **DNS Entry**: Add A record and PTR record in `hosts/dns/configuration.nix`:
   - `local-data`: `''"<hostname>.homelab.local. A <ip>"''`
   - `local-data-ptr`: `''"<ip> <hostname>.homelab.local"''`
5. **Prometheus Monitoring**: Add scrape config in `hosts/otel/configuration.nix`:
   ```nix
   {
     job_name = "<hostname>-node";
     static_configs = [
       {
         targets = ["<ip>:9100"];
         labels = { instance = "homelab-<hostname>"; };
       }
     ];
   }
   ```
6. **Git**: Stage new files with `git add` before running `nix flake check`

## 6. Common Pitfalls

### agenix Must Be Run From Inside `secrets/`

`agenix` resolves its rules file as `./secrets.nix` relative to the current
directory, and secret names are the bare filename (no `secrets/` prefix). Running
it from the repo root fails:

```
error: path '/home/amadeus/code/pve-nixos-homelab/secrets.nix' does not exist
```

- **WRONG** (from repo root): `agenix -e secrets/axon-gateway-env.age`
- **CORRECT**:
  ```bash
  cd secrets
  agenix -e axon-gateway-env.age
  ```

The matching entry in `secrets/secrets.nix` is keyed with the bare filename too
(e.g. `"axon-gateway-env.age".publicKeys = [...]`).

### Caddy Path Handling
When configuring Caddy reverse proxies, be careful with `handle` vs `handle_path`:
- **`handle /path*`**: Preserves the full path when proxying. Use this for services that expect their prefix in the URL (e.g., Loki expects `/loki/api/v1/push`, Tempo expects `/tempo/api/...`).
- **`handle_path /path*`**: Strips the prefix before proxying. Use this for services that expect requests at root (e.g., Grafana served at `/grafana` but expects `/` internally).

**Example - WRONG:**
```
handle_path /loki* {
  reverse_proxy localhost:3100  # Sends /api/v1/push instead of /loki/api/v1/push - 404!
}
```

**Example - CORRECT:**
```
handle /loki* {
  reverse_proxy localhost:3100  # Sends /loki/api/v1/push as expected
}
```

### Tailscale MagicDNS Does Not Resolve Between Homelab VMs

The `*.dropbear-butterfly.ts.net` MagicDNS names do **not** resolve from the
homelab VMs (e.g. `hermes` cannot resolve `homelab-mcp.dropbear-butterfly.ts.net`
→ `Name or service not known`). For service-to-service URLs between hosts, use
the local DNS names (`<host>.homelab.local`, served by the `dns` host) instead.
These carry step-ca TLS certs, which are trusted on any host importing
`modules/step-ca-trust.nix`.

- **WRONG** (in `services.hermes-agent.mcpServers`):
  `url = "https://homelab-mcp.dropbear-butterfly.ts.net/mcp";`  # NXDOMAIN from hermes
- **CORRECT**:
  `url = "https://mcp.homelab.local/mcp";`  # resolves + step-ca TLS trusted

### Hermes Rootless Podman: Stale `pause.pid` Breaks the Code/Terminal Backend

On `hermes` (192.168.2.155) the rootless-podman backend for the `terminal` /
`execute_code` / file tools can break with:

```
Error: cannot re-exec process to join the existing user namespace   (podman exit 125)
```

which Hermes surfaces as `execute_code` → *"Docker command is available but 'docker
version' failed. Check your Docker installation."*

**Root cause:** podman auto-selects `/run/user/995` as its runtime dir whenever that
directory exists (lingering is enabled for the `hermes` user, uid `995`), **regardless
of whether `XDG_RUNTIME_DIR` is set**. A stale `/run/user/995/libpod/tmp/pause.pid` left
over from a previous run points at a dead pid, so every new podman invocation tries to
join a user namespace that no longer exists and aborts. The `/tmp/storage-run-995`
runroot is a red herring, and `podman system migrate` does **not** help — it can't start
either while the stale pidfile is present.

**Surgical fix (no data loss — image storage under
`/var/lib/hermes/.local/share/containers/storage` is preserved):**

```bash
# run podman as the agent does: HOME set, XDG_RUNTIME_DIR unset, from a neutral cwd
sudo systemctl stop hermes-agent
sudo pkill -9 -u hermes -f conmon; sudo pkill -9 -u hermes -f pasta
sudo pkill -9 -u hermes -f run/podman-init           # kill June-leftover orphan container
sudo rm /run/user/995/libpod/tmp/pause.pid           # the ONE stale file
cd /tmp && sudo -u hermes env HOME=/var/lib/hermes podman rm -f <stale-container>  # if a dead
                                                     # persistent container record holds a lock
sudo systemctl start hermes-agent
# verify:
cd /tmp && sudo -u hermes env HOME=/var/lib/hermes podman version
```

Always invoke podman for this user as `cd /tmp && sudo -u hermes env
HOME=/var/lib/hermes podman ...` — the service sets `HOME=/var/lib/hermes`, so
reproduce its environment when debugging. SSH in as `amadeus@192.168.2.155` (root
login is disabled) and prefix privileged steps with `sudo`.

**Second variant — orphan podman helpers wedge the backend (fixed 2026-06-16):** the
real recurring root cause (beyond a stale `pause.pid`) is **orphan
`conmon`/`pasta`/`/run/podman-init` processes** left by a crashed/previous agent
instance. They keep holding the rootless user namespace + storage flocks, so every
new podman invocation aborts with `cannot re-exec process to join the existing user
namespace`, surfaced by `execute_code` as *"Docker version failed"*. `podman ps` may
also show the storage runroot at `/tmp/storage-run-<uid>` reporting `RunRoot ... not
writable` once that dir is disturbed.

**Why the orphans appear:** the gateway logs `Stale systemd unit detected:
hermes-agent.service has TimeoutStopSec=90s but drain_timeout=180s (expected >=210s).
systemd may SIGKILL the gateway mid-drain.` The hermes module ships
`TimeoutStopSec=90s`, but the agent drains for up to 180s on stop/restart — so on
every restart/redeploy systemd **SIGKILLs the agent mid-drain**, interrupting podman's
container teardown and orphaning the helpers. They accumulate across deploys until
podman wedges. Fixed declaratively by `TimeoutStopSec = lib.mkForce 210;` on the
service (prevents the unclean kill); the `ExecStartPre` guard below is the safety net
for any that still slip through.

Note the storage **runRoot stays on `/tmp/storage-run-<uid>`** and that is fine —
Hermes invokes podman with a sanitised environment that drops `XDG_RUNTIME_DIR`, so a
unit-level `environment.XDG_RUNTIME_DIR` pin does **not** move it (verified: conmon's
argv still showed `--runroot /tmp/storage-run-995`). Don't bother fighting the
runroot location; the failure is the orphans, not where the runroot lives.

Manual recovery (as `amadeus@`, with `sudo`): stop the agent, `pkill -9 -u hermes`
the `conmon`/`pasta`/`podman-init` orphans, remove the stale `pause.pid`, then
restart. This is now **automated in `ExecStartPre`** — the `podmanPauseGuard` in
`hosts/hermes/configuration.nix` reaps those orphans (and clears a stale `pause.pid`)
before the agent starts, so a plain `systemctl restart hermes-agent` / redeploy
self-heals it.

### Hermes API Server (Open WebUI) Ignores Top-Level `toolsets`

The Open WebUI chat-completions gateway is the `api_server` *platform*. Per
`hermes_cli/tools_config.py` (`_get_platform_tools`), every gateway platform resolves
its enabled tools from **`platform_toolsets.<platform>`** in `config.yaml`, and the
top-level `toolsets` list is **never consulted by the API server**. When
`platform_toolsets.api_server` is absent, the platform falls back to its built-in
`default_toolset` preset (`hermes-api-server`), which is why Open WebUI showed only a
trimmed ~13-tool set despite a fuller top-level `toolsets`.

- **Fix (declarative):** set `services.hermes-agent.settings.platform_toolsets.api_server`
  to the desired toolset keys (mirror the top-level `toolsets`). Each name must be a
  `CONFIGURABLE_TOOLSETS` key (`file`, `web`, `browser`, `terminal`, `code_execution`,
  `skills`, `memory`, `session_search`, `delegation`, …).
- **Do NOT** use `hermes config set` / hand-edit `~/.hermes/config.yaml` — that file is
  **merged** from the Nix store config on every activation by `hermes-config-merge`
  (`deep_merge(existing, nix)`, Nix wins for keys it sets), so manual edits to
  Nix-managed keys are overwritten on the next deploy. Note the merge only *adds/updates*
  keys; it never prunes, so keys removed from the Nix config (e.g. a retired
  `mcp_servers` entry) linger in the live file until removed by hand.
- **Verify live:** `GET http://localhost:8642/v1/toolsets` (Bearer = the API-server key)
  lists every toolset with its `enabled` flag for the `api_server` platform.
