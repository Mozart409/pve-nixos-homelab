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

### Commit Messages
- Use **single-line** conventional commits: `type(scope): summary`.
- **No commit body.** Do not add explanatory paragraphs, bullet lists, or
  `Co-authored-by`/tool trailers. The subject line is the whole message.

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
    -   **`just nixos-check` does NOT gate the colmena deploy.** It only checks
        `nixosConfigurations`, which use `mkHost` — and `mkHost` omits the
        home-manager/nixvim layer (see flake.nix). `colmenaHive` isn't a standard
        flake output, so `nix flake check` skips it entirely (`warning: unknown
        flake output 'colmenaHive'`). It is also mostly an *eval* gate, so
        build-phase failures (e.g. a failing patchPhase) slip through. A green
        `nixos-check` can therefore still fail `colmena apply` on every node.
    -   **Before committing/deploying any change to flake inputs or the
        home-manager/nixvim layer, build the hive:** `just colmena-build` (all
        nodes) or `just colmena-build-host <host>` (one node is enough —
        `home-manager-path` is shared across all nodes). This is the only gate
        that exercises the layer `colmena apply` actually builds.

4.  **Formatting**:
    -   Always run `just fmt` before finishing a task involving Nix files.

5.  **Post-Deployment Checklist** (after `colmena apply`):
    -   **Confirm activation on every node.** Each host must report `Activation
        successful`. A partial apply is common — e.g. the ssh-agent refuses to
        sign mid-push (`agent refused operation`) after the first few hosts, so
        some activate and the rest fail at "Push failed". Fix the agent and
        re-run; already-done hosts are no-ops.
    -   **Check for drift:** `just colmena-diff` should come back empty.
    -   **Restart services `colmena apply` does NOT bounce** (config written but
        not reloaded):
        -   `hermes` — `sudo systemctl restart hermes-agent` after SOUL.md /
            skill / `config.yaml` changes, and after any axon outage (it parks
            the axon-gateway MCP and won't auto-recover).
        -   `containers` — `sudo systemctl restart podman-axon-gateway` after
            editing axon-gateway `config.toml` backends.
        -   `caddy` (any host) — restart if newly-added vhosts leave certs stuck
            at HTTP 000 (step-ca ACME `badNonce` storm).
    -   **After a big flake update / package upgrade** (`chore(deps): …`, which
        bumps many packages at once): a green build does NOT mean runtime config
        survived. Version bumps silently break external integrations — e.g. Open
        WebUI 0.9.6 changed OAuth callback derivation (re-register Pocket ID
        callbacks), Jellyfin resets Known-proxies/SSO. Skim the upgraded package
        list and re-verify every auth / reverse-proxy / OIDC flow for services
        that talk to something external.
    -   **Smoke-test liveness with `curl`** from a host that trusts step-ca. The
        dashboard `health_checks` URLs are a ready-made set. Expect `200`; `302`
        (redirect to login) and `406` (MCP endpoints needing an `Accept` header)
        are also healthy — `000` means down or a TLS-trust failure.

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

### Open WebUI 0.9.6+ Derives the OAuth Callback From the Request Host (not `WEBUI_URL`)

Pocket ID (OIDC) sign-in to Open WebUI fails with *"Invalid callback URL, it might be
necessary for an admin to fix this"* after upgrading Open WebUI to **0.9.6** (e.g. the
`0.9.5 → 0.9.6` bump in the `chore(flake): upgrade pkgs` flake update).

**Root cause:** 0.9.6 changed OAuth redirect-URI handling ([#23203](https://github.com/open-webui/open-webui/pull/23203),
[#23128](https://github.com/open-webui/open-webui/issues/23128)). The callback **path is
unchanged** (`/oauth/oidc/callback`), but the full URL is now derived from the **actual
incoming request host** (forwarded through Caddy) rather than being pinned to `WEBUI_URL`.
The `containers` host is reachable from **two** origins (see `CORS_ALLOW_ORIGIN` in
`hosts/containers/open-webui/default.nix`):

- `https://homelab-containers.dropbear-butterfly.ts.net` (the `WEBUI_URL`)
- `https://containers.homelab.local`

Pre-0.9.6 the `redirect_uri` was always the `WEBUI_URL` one regardless of how you reached
the UI. Post-0.9.6, reaching the UI via `containers.homelab.local` sends
`redirect_uri=https://containers.homelab.local/oauth/oidc/callback`, which Pocket ID
rejects unless that exact URL is a registered callback.

**Confirm:** on the failing login, the browser address bar (when it bounces to Pocket ID)
shows the exact `redirect_uri=` query param Open WebUI is sending.

**Fix (Pocket ID admin UI — NOT a repo change):** in the Open WebUI OIDC client's allowed
**Callback URLs**, register *every* origin you use, each with the `/oauth/oidc/callback`
path:

```
https://homelab-containers.dropbear-butterfly.ts.net/oauth/oidc/callback
https://containers.homelab.local/oauth/oidc/callback
```

No Open WebUI restart needed — retry login immediately. The Nix config is correct; this is
purely the new 0.9.6 behavior surfacing the second origin.

### Multi-Disk VMs: Pin Disko Devices by `/dev/disk/by-id`, Never `/dev/sdX`

On a Proxmox VM with more than one disk, Linux `/dev/sdX` names follow disk
**enumeration order, which is not stable** across reboots or inside the
nixos-anywhere installer. On `jellyfin` (scsi0 = 32 GB OS, scsi1 = 768 GB media)
the names flipped between `sda`/`sdb` from one boot to the next — so hardcoding
`device = "/dev/sda"` is a coin-flip that can partition the wrong disk or build a
ZFS pool on the wrong device.

- **WRONG:** `device = lib.mkDefault "/dev/sda";`
- **CORRECT** (stable; encodes the Proxmox scsi index):
  ```nix
  device = lib.mkDefault "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"; # OS   (scsi0)
  device = lib.mkDefault "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1"; # data (scsi1)
  ```

Get the exact IDs from the running host with `ls -l /dev/disk/by-id/`. Changing
`device` on an already-installed host does **not** repartition — disko generates
runtime mounts by `/dev/disk/by-partlabel/*` and by zpool name, so a later
colmena apply is a no-op for disks. See `modules/disko-jellyfin.nix`.

### Hosts With Extra Disks / a Static IP: Deploy `nixos-anywhere .#<host>`, Not `deploy-minimal` + colmena

The usual flow (`iac-apply` → `deploy-minimal <ip>` → `colmena-apply-host`) only
works when the host's disk layout matches the shared `minimal` config (single OS
disk). Two traps for a host like `jellyfin`:

1. **Disko only runs during nixos-anywhere, never during `colmena apply`.**
   `deploy-minimal` partitions the **`minimal`** layout (OS disk only). A ZFS
   pool declared in the host's own disko module (e.g. `mediapool` in
   `disko-jellyfin.nix`) is therefore **never created**, and the host's `/media`
   mount fails on the colmena deploy.
2. **`minimal` uses `useDHCP = true`.** After `deploy-minimal`, a host that will
   later hold a static IP sits on a **DHCP lease**, not its final address, so
   `colmena-apply-host` (which targets the static IP from `hostAddrs`) can't
   reach it. (On jellyfin the DHCP lease was even a *different* host's static IP.)

**Fix:** for any host with extra disks or a disko layout beyond the OS disk,
deploy the full config directly so disko builds every disk and the static IP
lands in one shot:
```bash
ssh <current-dhcp-ip> lsblk        # verify disk targeting first (pin by-id, above)
just deploy <host> <current-dhcp-ip>   # nixos-anywhere --flake .#<host>
# host reboots onto its static IP; then add the home-manager/nixvim layer:
just colmena-apply-host <host>
```

### Reprovisioned Host → agenix "no identity matched any of the recipients"

nixos-anywhere generates a **fresh SSH host key** on every (re)install, so any
agenix secret the host consumes must list that new key as a recipient or
activation fails:
```
age: error: no identity matched any of the recipients
Activation script snippet 'agenixInstall' failed (1)
```

**Fix:** add the new host key to `secrets/secrets.nix` and re-key:
```bash
just get-host-key <ip>          # or: ssh-keyscan -t ed25519 <ip>
# add `hostX = "ssh-ed25519 ...";` and include it in the relevant publicKeys
just reencrypt                  # agenix -r: re-encrypts every secret to current recipients
```
Every host runs Tailscale, so a new host almost always needs adding to the
`users` list (recipients of `tailscale-auth-key.age`).

### Jellyfin SSO (OIDC) Behind Caddy: `redirect_uri` Comes Out `http` → "Invalid callback URL"

Caddy terminates TLS and reverse-proxies to Jellyfin over plain HTTP on
`localhost:8096`, so Jellyfin sees the request scheme as `http` and the SSO-Auth
plugin builds an `http://…/sso/OID/redirect/<provider>` callback. Pocket ID (or
any IdP) rejects it because only the `https://` callback is registered.

- **Fix (plugin):** set the SSO-Auth provider's **Scheme Override = `https`**.
- **Fix (systemic):** Jellyfin Dashboard → Networking → **Known proxies** →
  `127.0.0.1`, `::1`, then restart Jellyfin so it honors `X-Forwarded-Proto`.

More Jellyfin OIDC notes:
- The upstream plugin (`9p4/jellyfin-plugin-sso`) is **archived**; use the
  maintained fork `K0lin/jellyfin-plugin-sso`, pinned in
  `hosts/jellyfin/sso-plugin.nix`. No NixOS option exists — a oneshot copies the
  DLLs into `/var/lib/jellyfin/plugins/` before jellyfin starts (copy, not
  symlink, so Jellyfin can rewrite `meta.json`). The plugin's `targetAbi` must
  match `services.jellyfin.package.version`.
- The **OpenID Endpoint** is fetched **server-side by the VM**; verify the VM can
  resolve/reach it (`curl …/.well-known/openid-configuration`) — MagicDNS
  `*.ts.net` names don't always resolve between homelab VMs.
- Plugin/OIDC settings, Known-proxies, and login-page branding live in Jellyfin's
  **mutable state**, not in Nix — they must be redone after a reprovision.

## 7. Hermes Agent Access to This Repo (feature-branch dev)

The Hermes agent (driven from Open WebUI) can develop changes to *this* repo
inside its podman sandbox. It commits on feature branches; a host-side service
pushes them to Forgejo. `main` is branch-protected, so the bot can never land
changes directly — you review the branch, open the PR, and deploy with `colmena`.
The plan/design lives in `hosts/hermes/pve-nixos-homelab.md`.

### One-time Forgejo setup (done in the web UI, not in this repo)
- Add `hermes-bot` as a **Write** collaborator on `amadeus/pve-nixos-homelab`.
- Protect `main`: block direct pushes (no push whitelist, or whitelist only you)
  so changes must go through pull requests.
- Auto-PR is intentionally **off** — no API token is configured. The host service
  only pushes the branch; you open the PR yourself.

### How it works (declarative, in `hosts/hermes/configuration.nix`)
- Access reuses the existing `hermes-forgejo-ssh` key (same `hermes-bot` account
  as the Obsidian vault, same `forgejo.homelab.local:2222` host the `~/.ssh/config`
  already routes). **No new secret.** The key stays host-side — never mounted into
  the sandbox.
- The repo is cloned at `~/workspace/pve-nixos-homelab` (`$HOMELAB_REPO_PATH`) and
  bind-mounted read-write into the sandbox. `hermes-repo-sync.{service,timer,path}`
  clones-or-fetches and pushes the current feature branch (never `main`, only when
  it is ahead of `origin/main`).
- The sandbox has `nix` via the **host nix-daemon**: `/nix` is bind-mounted
  read-only (store + the `0666` daemon socket) and the container runs with
  `NIX_REMOTE=daemon`. So the agent can `nix flake check` / `nix develop -c just …`
  to validate flake changes; builds run on the host daemon (no host root, no
  access to secrets). See the security note in `hosts/hermes/pve-nixos-homelab.md`.
- The agent loads the `homelab-config-repo` skill
  (`hosts/hermes/skills/development/homelab-config-repo/SKILL.md`) describing this
  workflow.

### Login-shell PATH gotcha (`nix: command not found`)
Hermes runs terminal commands through a **login shell**, and the nikolaik image's
`/etc/profile` hard-resets `PATH` to a fixed default — wiping `docker_env.PATH`
(which only survives *non-login* shells). That made the agent report
`nix: command not found` even though `/nix` was mounted and `NIX_REMOTE` was set.
Fixed by bind-mounting `/etc/profile.d/hermes-nix.sh` (`nixProfileScript`) that
re-adds `${pkgs.nix}/bin` to `PATH`; `/etc/profile` sources `/etc/profile.d/*.sh`
*after* the reset, so it survives `bash -lc`. Only `PATH` is reset by
`/etc/profile` — the `NIX_*` env vars survive untouched.

### Agent workflow (enforced by SOUL.md)
- Never commits to `main`; one feature branch per task, started from a fresh
  `origin/main` (`git switch -c feat/<slug> origin/main`).
- Validates with `nix develop -c just fmt`, then a **scoped per-host eval** —
  `nix eval ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"`
  for each edited host — NOT the full `just nixos-check` / `nix flake check`,
  which evaluates all ~16 hosts and gets OOM-killed (exit 137) on the host
  nix-daemon from the sandbox. The full check stays the user's pre-merge gate.
- Commits **through the dev shell** (`nix develop -c git commit`) so the lefthook
  `alejandra`/`keep-sorted` pre-commit hooks resolve; a bare `git commit` fails
  them in the sandbox (those tools aren't on the container PATH). The host pushes
  the branch automatically within seconds.

### Deploy-time checks (cannot be validated offline)
- In-sandbox: `nix --version` then a scoped `nix eval` (see above) in
  `$HOMELAB_REPO_PATH` — confirms the daemon-over-socket path works under the user
  namespace. (Verified 2026-06-25 on `feat/validate-workflow`: `nix` 2.34.7,
  `htop` change evaluated clean; the full `nix flake check` OOM-kills the `hermes`
  config in the sandbox, which is why validation is scoped per host.)
- Confirm `execute_code` still finds python3/node after the sandbox `PATH` change.
- An agent commit on a `feat/*` branch should appear on Forgejo within seconds; a
  commit attempt on `main` is rejected by branch protection.
