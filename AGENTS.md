# Agent Guidelines for pve-nixos-homelab

This repository contains the NixOS configurations and Infrastructure as Code (OpenTofu) for a Proxmox-based homelab. It currently manages the `database` and `otel` hosts using Nix Flakes, Colmena, and Disko.

## 1. Build, Lint, and Test Commands

The project uses `just` as a command runner. Always prefer `just` commands over raw `nix` or `colmena` commands when available.

### Core Commands
- **Check Configuration**: `just nixos-check`
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
- **VM Integration Test**: `just nixos-test-vm <host>`
  - Boots a real QEMU VM from the host's actual `hosts/<host>/configuration.nix`
    and asserts it reaches `multi-user.target` and its primary services
    respond (e.g. dns: unbound answers `dig`; otel: prometheus/grafana/loki/
    otel-collector respond on their ports; database: postgresql accepts
    connections and ensureDatabases/ensureUsers exist).
  - Covers `dns`, `otel`, `database` today (`tests/hosts/*.nix`).
  - This is NOT a substitute for `just colmena-build` -- it deliberately
    skips comin and the home-manager/nixvim layer (see `tests/lib.nix`) to
    stay fast and free of real network dependencies. It IS a substitute for
    manually SSHing into a freshly-deployed host to poke at its services.
  - Not part of `just check` / `just nixos-check` / any bare `nix flake
    check` -- these build real QEMU VMs, which is much heavier than the
    dry-run eval those already do, and is exactly the class of cost this
    repo has already worked around (see `.woodpecker/nix.yml`). Run it
    explicitly, and not on every push.
- **Preview a build without deploying**: `just colmena-build-host <host>`
  - There is no drift/diff recipe; compare `readlink /run/current-system` on the
    host against the path this prints if you need to check what is deployed.

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
  - This repo uses **direnv** (`.envrc` = `use flake`). With the direnv shell
    active (the default in this checkout), all dev tools are already on PATH —
    run `just`, `alejandra`, `nix`, `tofu`, `cog`, `colmena`, … **directly,
    without `nix develop -c` wrapping**. Only reach for `nix develop` on a
    machine where direnv is not loaded.
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
    -   `just fmt` is the required check (see below); `just nixos-check` is
        optional, not a default step after every Nix edit.
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
    -   **Restart services `colmena apply` does NOT bounce** (config written but
        not reloaded):
        -   `hermes` — `sudo systemctl restart hermes-agent` after SOUL.md /
            skill / `config.yaml` changes, and after any axon outage (it parks
            the axon-gateway MCP and won't auto-recover).
        -   `containers` — axon-gateway backend/config edits used to need a
            manual `sudo systemctl restart podman-axon-gateway` (the container's
            generated unit doesn't change when only the mounted config.toml's
            *contents* do). As of 2026-08-15 `config.toml`'s text is hashed into
            a `CONFIG_HASH` env var on the container (see
            `hosts/containers/axon-gateway/default.nix`), so the unit changes
            and `colmena apply` restarts it on its own — no manual step needed.
        -   `caddy` (any host) — restart if newly-added vhosts leave certs stuck
            at HTTP 000 (step-ca ACME `badNonce` storm).
     -   **Systemd restart nonces:** NixOS only restarts a service when its
         generated unit changes. Secrets and files rewritten at stable paths can
         therefore change without restarting the consumer:
         -   `hosts/mcp_vm/configuration.nix` — bump `secretNonce` when an MCP
             credential changes; it is wired to the secret-consuming units'
             `restartTriggers`.
         -   `hosts/hermes/configuration.nix` — bump `secretNonce` when a secret,
             `SOUL.md`, `USER.md`, `config.yaml`, or skill changes; it triggers
             both `hermes-agent` and `hermes-config-check`.
         -   `hosts/containers/axon-gateway/default.nix` — `configText` is hashed
             into `CONFIG_HASH`, so changing the declarative gateway config
             changes the generated container unit automatically.
         -   `modules/loki-logs.nix` — changes to the selected units or Fluent
             Bit pipeline change the generated `fluent-bit.service`; no manual
             nonce is needed. After deployment, verify `systemctl status
             fluent-bit` and its journal on the target host.
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

6.  **Git Remotes: GitHub Is a Manual Mirror — Check It and Say So**

    There are two remotes, and they are **not** kept in sync automatically.
    Server-side push mirroring is deliberately **not** configured.

    -   `origin` → Forgejo (`forgejo.homelab.local:2222`). **Canonical.** All
        agent commits, branches and PRs go here, and only here.
    -   `github` → `https://github.com/Mozart409/pve-nixos-homelab.git`.
        A mirror that only ever advances when a human pushes to it, so it
        silently falls behind.

    **At the end of any task that produced commits, check the gap and tell the
    user.** Agents push to Forgejo only — never push to `github` yourself.

    ```bash
    git status --short                       # working tree clean? anything unstaged?
    git fetch github                         # refresh the mirror's ref
    git log --oneline github/main..main      # commits GitHub is missing
    ```

    If `github/main..main` is non-empty, end the task with an explicit nudge,
    e.g. *"GitHub is 3 commits behind Forgejo — run `just sync-remotes` to
    sync it."* Report the count and let the user run it.

    For syncing by hand, `just sync-remotes` (`scripts/sync-remotes.sh`) is the
    supported path: it fetches both remotes, fast-forwards `main` onto whatever
    is newest (merging in any commits that exist only on `github`, e.g. pushed
    from another machine), then pushes `origin` first and `github` second —
    sequential pushes, never a multi-URL remote. It aborts instead of guessing
    on diverged history with `origin`, merge conflicts, or a dirty tree. This
    is for the user; agents still push to Forgejo only.

    **Never add GitHub as a second push URL on `origin`.** It looks like free
    mirroring and instead produces split-brain, because git does not push to
    multiple URLs atomically:

    -   Forgejo rejects the push (agents landed a PR, so it is ahead) while
        GitHub accepts it. The remotes now disagree.
    -   Git still records `origin/main` at the pushed SHA, because *one* URL
        succeeded — poisoning the remote-tracking reflog.
    -   `pull.rebase = true` is set, and `git pull --rebase` defaults to
        `--fork-point`, which reads that reflog to decide which local commits
        upstream has already seen. It finds the commit there, concludes upstream
        dropped it deliberately, and **silently discards it** — no conflict, no
        warning, the commit is simply gone from the rebased branch.

    This cost a real commit on 2026-08-02 (`fix(cache): grant atticd secret
    access by group`), which vanished from the working tree while still existing
    on GitHub and in the reflog. Recover such a commit with
    `git reflog` + `git cherry-pick <sha>`.

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
   - Add to `hostAddrs` with the host's `<hostname>.homelab.local` name (not its
     raw IP — add the DNS record in step 4 first) and its Tailscale name
   - Add to `nixosConfigurations` using `mkHost`
   - Add to `colmenaHive` with deployment settings
3. **Infrastructure (OpenTofu)**: Add VM resource in `iac/main.tf` and update outputs
4. **DNS Entry**: Add A record and PTR record in `hosts/dns/configuration.nix`:
   - `local-data`: `''"<hostname>.homelab.local. A <ip>"''`
   - `local-data-ptr`: `''"<ip> <hostname>.homelab.local"''`
5. **Prometheus Monitoring**: Add scrape config in `hosts/otel/configuration.nix`.
   Address the target by its DNS name from step 4, not its IP, and always set
   `labels.instance` — that label overrides the one prometheus derives from the
   target address, which is what keeps series stable if the host is ever re-IP'd
   or re-addressed:
   ```nix
   {
     job_name = "<hostname>-node";
     static_configs = [
       {
         targets = ["<hostname>.homelab.local:9100"];
         labels = { instance = "homelab-<hostname>"; };
       }
     ];
   }
   ```
   Note prometheus resolves a target's name when it dials the connection, not on
   every scrape (it holds HTTP keep-alives and has no DNS cache), so an A-record
   change is only picked up once the connection drops or prometheus restarts.
   The one job kept on a raw IP is `dns-node`, so the resolver host stays
   observable when unbound is down.
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

### Tailscale ACLs Filter Ports Before the Host Firewall Ever Sees Them

Every host trusts the `tailscale0` interface via
`networking.firewall.trustedInterfaces`, which shows up as
`-A nixos-fw -i tailscale0 -j nixos-fw-accept`. That rule is **not** evidence a
port is reachable over Tailscale — the tailnet policy (ACLs) drops traffic
*before* it is ever delivered to the host firewall. The policy lives in the
Tailscale admin console, **not in this repo**, so nothing under `modules/` or
`hosts/` will reveal it.

**Signature:** a service fails *identically* over the Tailscale name, over
`<host>.homelab.internal`, and over the raw LAN IP, while a different
protocol/port to the same host keeps working. A tailnet ACL is
address-independent, so it breaks every path at once; a host firewall rule is
per-interface and cannot.

This cost a long diagnosis on 2026-08-12: mosh from an iPhone to `development`
failed on every path while SSH worked. The host was entirely healthy —
`mosh-server` present, a UTF-8 locale (mosh refuses to start without one), a
clean `MOSH CONNECT` handshake through a real SSH login, `tailscale0` trusted,
and UDP 60000-61000 open in `nixos-fw`. The ACL was dropping mosh's UDP range.

**Clear the host side first.** These two commands rule out every host-side
theory at once:

```bash
ssh <host> -- mosh-server new -s -c 8 | head -1   # MOSH CONNECT must be line 1
sudo iptables -S nixos-fw | grep -E 'udp|tailscale0'
```

The first is the exact bootstrap a mosh client runs, so it catches a missing
binary, a non-UTF-8 locale, and any shell-init output that would corrupt the
handshake. (It leaves a detached `mosh-server` that exits by itself after 60s
with no client.) If it prints `MOSH CONNECT` and the firewall rules are present,
**stop auditing the host and go read the tailnet ACLs.**

The grant must cover the UDP range, not just TCP 22 — e.g.:

```json
{
  "action": "accept",
  "src":    ["autogroup:member"],
  "dst":    ["tag:homelab:60000-61000"],
  "proto":  "udp"
}
```

Illustrative only — match it to this tailnet's actual tags and groups.

### Hermes Terminal/Code/File Backend Is `local` (Not Podman)

As of the `local`-backend migration, `hermes` no longer runs its `terminal` /
`execute_code` / file tools inside a rootless-podman jail. `terminal.backend =
"local"` runs them as host subprocesses of the agent — i.e. as the `hermes` service
user — confined by the systemd unit sandbox (`ProtectSystem=strict`, `PrivateTmp`,
`NoNewPrivileges`, plus a `ReadOnlyPaths` lock on `config.yaml`/`SOUL.md`/`USER.md`
and `TasksMax`/`LimitNPROC`/`MemoryHigh` caps). There is no libpod DB, runroot, pause
process, or persistent container — so the whole class of "execute_code → Docker
version failed" wedges (stale `pause.pid`, orphan `conmon`/`pasta` helpers, undetermined
runroot) is gone by construction. If the tools misbehave, debug the `hermes-agent`
unit directly (`journalctl -u hermes-agent`, `systemctl status hermes-agent`) — there
is no podman layer to reset. The old podman image storage under
`/var/lib/hermes/.local/share/containers` is inert leftover and can be GC'd.

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

### Hermes Fails OPEN on a Malformed `config.yaml` (silent loss of every setting)

Open WebUI shows *"Uh-oh! There was an issue with the response."* and the journal has:

```
provider=deepseek base_url=https://api.deepseek.com/v1 model= summary=HTTP 400:
The supported API model names are deepseek-v4-pro or deepseek-v4-flash, but you passed .
```

An **empty `model=`** with a correct `provider`/`base_url` is the signature of a
**config.yaml that hermes could not parse**. `gateway/run.py`'s
`_load_gateway_config()` catches the YAML error and substitutes an **empty dict** —
the agent starts "successfully" with *every* override silently discarded
(`toolsets`, `platform_toolsets`, `approvals`, `terminal.backend`, `timezone`,
`mcp_servers`, …). `provider`/`base_url`/`api_key` still look right because they come
from a separate env bridge; `model` has **no env fallback**, so it resolves to `""`.

Confirm with the startup log — it says so explicitly, and saves a copy:

```bash
sudo journalctl -u hermes-agent | grep -A3 'Failed to parse'
# ⚠️  hermes config: Failed to parse …/config.yaml … Falling back to default config
ls /var/lib/hermes/.hermes/config.yaml.corrupt.*
```

**Root cause (2026-07-24 → 07-27 incident): two writers with incompatible list
indentation.** `moshi-hook install` rewrites `$HERMES_HOME/.hermes/config.yaml` to
register its plugin using 4-space sequence items; the hermes-agent module's
activation-time `hermes-config-merge` re-dumps the **whole** file via PyYAML using
2-space items. Neither recognizes the other's form, so `install` **inserts** a
duplicate `    - moshi-hooks` above the merge's `  - moshi-hooks` — two sequence
items at different depths, which is unparseable:

```yaml
plugins:
  enabled:
    - moshi-hooks   # inserted by moshi-hook install (4-space)
  - moshi-hooks     # written by hermes-config-merge (2-space)
```

The agent ran three days on built-in defaults before anyone chatted with it, so
**absence of errors is not evidence the config is live.**

- **Fixed by:** a version-stamped guard so `moshi-hook install` runs once per
  release instead of every boot (`hosts/hermes/moshi-hook.nix`), plus a
  `hermes-config-check` oneshot ordered after it and `requires`-d by `hermes-agent`
  (`hosts/hermes/configuration.nix`) that repairs mixed-indent duplicates and
  **blocks startup** on an unparseable config or a missing `model`.
- **Bumping `moshi-hook`'s `version` re-triggers the corruption once — expected.**
  The stamp is keyed on the version, so a bump in `modules/moshi-hook.nix` makes
  `install` run again on the next deploy, and it will re-insert the mis-indented
  duplicate. `hermes-config-check` repairs it before `hermes-agent` starts, so the
  deploy still succeeds — you will just see `repaired mixed-indent/duplicate
  sequence items` in its journal. That line is the guard working, not a new bug.
  Only investigate if the unit *fails* (it blocks the agent when it cannot repair).
- **Verify a config is actually live** (do this after any hermes deploy):
  ```bash
  sudo systemctl status hermes-config-check      # must be active/exited
  sudo journalctl -u hermes-agent -b | grep -c 'Falling back to default config'   # must be 0
  ```
- **General rule:** `hermes-config-merge` does a `deep_merge(existing, nix)` and
  **re-dumps the entire file**, so it reformats keys Nix does not manage and never
  prunes removed ones. Any third-party tool that edits `config.yaml` in place will
  eventually collide with it.

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

### nixosTest Integration Tests: Scope and Secret Fixtures

`tests/` builds real QEMU VMs directly from `hosts/<host>/configuration.nix`
(`disko.nixosModules.disko` + `agenix.nixosModules.default` added manually,
mirroring what `mkHost` does -- see `tests/lib.nix`), but skips comin and the
home-manager/nixvim layer entirely. That's a deliberate scope decision: comin
needs a real forgejo server and home-manager/nixvim is slow to build, and
neither is required for `multi-user.target` (comin.service is only
`wantedBy=multi-user.target`, nothing requires it).

**agenix secrets fail softly in these tests, by design.** A nixosTest VM
generates fresh, ephemeral SSH host keys, which never match any recipient in
`secrets/secrets.nix` -- so every real secret fails to decrypt, exactly like
the "no identity matched any of the recipients" incident above, and boot
still succeeds (agenix's activation script decrypts each secret independently
inside one shared `agenixInstall` snippet; a failure only records status, it
never aborts the loop, so unrelated secrets on the same host are unaffected).

For the 2 secrets whose consuming PRIMARY service the otel test asserts on
(`grafana-secret-key`, `grafana-oidc-secret` -- grafana reads both via
`$__file{...}` at startup and won't come up without them), the test instead
overrides `age.identityPaths` to a dedicated, disposable, committed test-only
age identity (`tests/fixtures/test-age-identity.txt`) and points just those
two secrets at dummy values encrypted to its public key
(`tests/fixtures/secrets/*.age`). This makes agenix's real decrypt pipeline
succeed for real inside the VM -- not a bypass, the legitimate mechanism.
Everything else (tailscale-auth-key, axon-gateway-env,
woodpecker-metrics-token, every database-host role password, pgadmin's
secrets, osquery's fleet-enroll-secret) is left to fail softly and is never
asserted on. See `tests/fixtures/README.md` to regenerate.

**Static IPs never take effect.** `hosts/dns`, `hosts/otel`, `hosts/database`
all set `networking.interfaces.ens18...`, a device that doesn't exist in a
QEMU test VM. `tests/lib.nix`'s `clearStaticNetworking` module removes just
that interface definition and `networking.defaultGateway` -- NOT
`networking.useDHCP`, which must stay untouched so the test framework's own
auto-provisioned interface still comes up (needed for `network-online.target`,
a real dependency of e.g. `unbound.service` on dns).

**Network-dependent integrations are expected to be non-functional and are
never asserted on**: tailscaled-autoconnect, comin's forgejo pull, Caddy's
step-ca ACME cert issuance (`ca.homelab.local` is unreachable), osquery
enrollment, `services.loki-logs` shipping to `loki.homelab.local`, the
alertmanager-axon-bridge webhook relay. None of these block
`multi-user.target` or the services under test.

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

### Woodpecker CI Needs Two Things Nix Cannot Declare

Woodpecker runs on its **own** host (`hosts/woodpecker/`, 192.168.2.182), served
at `https://ci.homelab.local`. Server and agent share that VM deliberately, so
gRPC stays on loopback — it is authenticated by the shared agent secret but
**not encrypted** (`WOODPECKER_GRPC_SECURE` defaults to false), so splitting them
across hosts would put plaintext agent traffic on the LAN and require opening
port 9000. Two setup steps live outside the repo:

1. **The Forgejo OAuth2 application.** Forgejo has no declarative API for this.
   Create it at `/user/settings/applications` (per-user) or
   `/admin/settings/applications` (instance-wide) with redirect URI **exactly**
   `https://ci.homelab.local/authorize`, then put the generated pair into
   `secrets/woodpecker-server-env.age` as `WOODPECKER_FORGEJO_CLIENT` /
   `WOODPECKER_FORGEJO_SECRET`.
2. **`WOODPECKER_AGENT_SECRET` must be identical** in
   `woodpecker-server-env.age` and `woodpecker-agent-env.age`
   (`pwgen -sc 48 1`). A mismatch shows up only as the agent failing to
   register — the server starts fine and the UI looks healthy but no pipeline
   ever picks up.

`WOODPECKER_HOST` is baked into the OAuth redirect *and* into every webhook
Woodpecker registers on a repo, so changing it later means re-registering
webhooks on every repo. Treat `ci.homelab.local` as permanent.

Gotchas that cost time on the podman-compose prototype and are already handled
in the Nix config — do not "simplify" them away:

- `services.forgejo.settings.webhook.ALLOWED_HOST_LIST` (on the **forgejo** host)
  must include `ci.homelab.local`. Forgejo refuses to deliver webhooks to private
  addresses by default, so without it pushes **silently** never trigger a
  pipeline. This is the only Woodpecker-related setting outside `hosts/woodpecker/`.
- The agent is **not** a container — it is a native systemd unit running the
  `woodpecker-agent` binary. Only the pipeline *step* containers are containers,
  and the agent creates them by asking podman over its socket. That socket is
  effectively root on the VM, which is why `WOODPECKER_OPEN = "false"` matters
  and why this does not live on the git forge.
- The agent runs as a **static** `woodpecker-agent` user with
  `DynamicUser`/`PrivateUsers` forced off. The module's default `DynamicUser`
  implies a user namespace in which the `podman` supplementary group no longer
  matches the socket owner, and every docker-API call fails with a permission
  error.
- `WOODPECKER_AGENT_CONFIG_FILE` points into the agent's `StateDirectory`. Its
  default (`/etc/woodpecker/agent.conf`) is unwritable under
  `ProtectSystem=strict`; the failure is non-fatal, so the symptom is instead a
  **new agent registered on every restart**, piling up dead agents in the UI.
- `WOODPECKER_BACKEND_DOCKER_VOLUMES` mounts the host CA bundle into every step
  container. Pipeline clone steps hit `forgejo.homelab.local`, whose step-ca
  cert is not in the stock image trust store — without it the clone dies with
  `x509: certificate signed by unknown authority`.
- Rootless podman + `docker:dind`-style plugins do not work. Use Buildah or
  Kaniko for image builds.

## 7. Hermes Agent Access to This Repo (feature-branch dev)

The Hermes agent (driven from Open WebUI) can develop changes to *this* repo. Under
the `local` terminal backend it runs its file/terminal/nix tools **as the `hermes`
user directly on the VM** (no container). It commits on feature branches and **pushes
them to Forgejo itself** with the `hermes-forgejo-ssh` key on `~/.ssh`. `main` is
branch-protected, so the bot can never land changes directly — you review the branch,
open the PR, and deploy with `colmena`.

### One-time Forgejo setup (done in the web UI, not in this repo)
- Add `hermes-bot` as a **Write** collaborator on `amadeus/pve-nixos-homelab`.
- Protect `main`: block direct pushes (no push whitelist, or whitelist only you)
  so changes must go through pull requests.
- Auto-PR is intentionally **off** — no API token is configured. The agent only
  pushes the branch; you open the PR yourself.

### How it works (declarative, in `hosts/hermes/configuration.nix`)
- Access reuses the existing `hermes-forgejo-ssh` key (same `hermes-bot` account
  as the Obsidian vault, same `forgejo.homelab.local:2222` host the `~/.ssh/config`
  already routes). **No new secret.** Under `local` the agent runs as `hermes`, so
  it reads the key directly and pushes on its own.
- The checkout lives at `~/workspace/pve-nixos-homelab` (`$HOMELAB_REPO_PATH`). The
  `hermes-repo-sync` oneshot + timer only **bootstrap** it (clone-if-missing + a
  periodic `git fetch` to keep `origin/main` fresh); it never commits, merges, or
  pushes. The agent fetches + pushes feature branches itself.
- `nix` is on the agent's service PATH (via `extraPackages`) and talks to the **host
  nix-daemon natively** — no socket bind-mount, no `NIX_REMOTE`. So the agent can
  `nix develop -c just …` / scoped `nix eval` to validate flake changes.
- Config integrity: `config.yaml`, `SOUL.md`, and `USER.md` are bound **read-only**
  to the running agent via `serviceConfig.ReadOnlyPaths` (they are (re)written by a
  root activation script outside the unit namespace), so the agent cannot rewrite its
  own config/system prompt — Nix stays the source of truth.
- The agent loads the `homelab-config-repo` skill
  (`hosts/hermes/skills/development/homelab-config-repo/SKILL.md`) describing this
  workflow.

### Agent workflow (enforced by SOUL.md)
- Never commits to `main`; one feature branch per task, started from a fresh
  `origin/main` (`git switch -c feat/<slug> origin/main`).
- Validates with `nix develop -c just fmt`, then a **scoped per-host eval** —
  `nix eval ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"`
  for each edited host — NOT the full `just nixos-check` / `nix flake check`,
  which evaluates all ~16 hosts and gets OOM-killed (exit 137) on the host
  nix-daemon. The full check stays the user's pre-merge gate.
- Commits **through the dev shell** (`nix develop -c git commit`) so the lefthook
  `alejandra`/`keep-sorted` pre-commit hooks resolve; a bare `git commit` fails them.
  Then pushes the feature branch itself (`git push -u origin feat/<slug>`).

### Deploy-time checks (cannot be validated offline)
- Confirm `execute_code` finds `python3`/`node`, and `terminal` finds `nix`/`git`/
  `ssh`, from the `local`-backend service PATH (`extraPackages`).
- Confirm the config lock: as `hermes`, writing `config.yaml`/`SOUL.md`/`USER.md`
  fails (read-only), while other `~/.hermes/` writes succeed.
- An agent-pushed `feat/*` branch should appear on Forgejo; a push to `main` is
  rejected by branch protection.

## 8. Claude Code Permissions on `development`

Claude Code runs **unattended** on this host, so its permission config is a
guardrail, not a prompt. Do not go looking for it in `~/.claude/settings.json`
— that file is mutable and partly machine-written.

### Source of truth

**`modules/claude-permissions-data.nix`** — plain data (`allow`, `deny`,
`defaultMode`, plus `webSearchDomains`), imported by exactly two consumers so
the lists cannot drift:

| Module | Role |
| --- | --- |
| `modules/claude-permissions.nix` | **Writer.** `claude-permissions-apply` jq-merges the three keys and the WebSearch restriction hook into `~/.claude/settings.json` at boot (`claude-permissions.service`). |
| `modules/claude-settings-verify.nix` | **Checker.** Re-reads the same data and confirms it survived; notifies `notify.iphone_von_amadeus` via the axon gateway on drift. Runs after every boot plus a daily timer. |

Both are imported by `hosts/development/configuration.nix`.

**Editing `~/.claude/settings.json` by hand does not stick.** The merge is
right-biased and wholesale for `permissions.{allow,deny,defaultMode}` and for
the `PreToolUse` hook group with `matcher == "WebSearch"` — the next boot
overwrites them, and the daily verify sends a push notification in the
meantime. Keys outside those (model, theme, other hooks) are left alone and
*are* hand-maintained. Change permissions in the data module and redeploy.

### Why `defaultMode = "dontAsk"`

`dontAsk` **auto-denies** anything not pre-approved instead of prompting. That is
the point: with nobody watching, a prompt is an indefinite hang.

| Mode | Unlisted action | Honors `deny` | Unattended |
| --- | --- | --- | --- |
| `dontAsk` | denied | yes | ✅ fails closed |
| `auto` | classifier decides, still prompts on risky calls | yes | ❌ hangs |
| `acceptEdits` | prompts for anything beyond file edits | yes | ❌ hangs |
| `bypassPermissions` | allowed | yes | ⚠️ fails open |

`auto` is the mode the UI labels "Auto" (Shift+Tab cycle); it reduces prompts via
a safety classifier but does not eliminate them, and its availability depends on
account/model eligibility, so it can silently drop out of the cycle. It is **not**
a substitute here. `bypassPermissions` still honors `deny`, but discards the allow
list as the thing defining scope. `dontAsk` is the only mode where the deny list
is the guardrail *and* nothing blocks.

### Consequences worth knowing

- **Denials are silent.** A command outside `allow` fails mid-task with no
  prompt — it looks like a broken tool, not a permission problem. The allow list
  is load-bearing; add to it in `claude-permissions-data.nix` rather than
  working around a refusal.
- **`AskUserQuestion` is denied.** Agents cannot ask clarifying questions in this
  mode. They must assume and proceed, then state the assumption.
- **Precedence is `deny` > `ask` > `allow`**, which is how `Bash(git push:*)` is
  granted while `Bash(git push --force*)` stays blocked. Deny rules apply in
  every mode, `bypassPermissions` included.
- The deny list is what makes deploys human-gated: `nixos-rebuild`, `nh os`,
  `colmena apply`, `just deploy*`, `gh pr merge`, and force-push are all blocked
  regardless of mode.
- **Subagents need narrow `Bash(<cmd>:*)` rules, not a broad `Bash`.** Delegated
  agents (Explore/Plan/General-purpose) check their tool calls against the same
  allow list, but only narrow rules flow to them: a bare `Bash` / `Bash(*)`
  allow is unreliable for subagents and is stripped entirely in auto mode. The
  interpreter/utility rules under the "Subagents" group in
  `claude-permissions-data.nix` therefore hold in both dontAsk (unattended) and
  auto (interactive) sessions. They are session-wide, so the main agent gains
  them too — the deny list still governs.

### MCP tools are allow-listed per server, never with `mcp__*`

`dontAsk` denies every unlisted MCP call silently, and a bare `mcp__*` allow
rule is **skipped by Claude Code with a warning** — it approves nothing. The
only valid `allow` forms are a server-level `mcp__<server>__*` wildcard or an
exact `mcp__<server>__<tool>` name. Rules live in `modules/claude-permissions-data.nix`
next to the Bash entries: the whole `axon-gateway` server (Home Assistant,
Loki, Prometheus, PBS, Postgres), the whole `internal-dashboard` server
(link tools), and the whole `ventara-gateway` server (the separate
nixos-ventara-ai deployment's own axon-gateway instance). Add any new
server/tool by name there, not with `mcp__*`.
(Server/tool names keep hyphens — only characters outside `[a-zA-Z0-9_-]`
become underscores.)

### `Monitor` is allowed bare

`Monitor` runs its target command line under tracing but changes no state and
writes nothing, so there is no deny case for it; like `WebSearch` it takes no
path/domain pattern, and it is allow-listed bare in `claude-permissions-data.nix`.
The deny list still guards whatever the underlying command would do.

### Scheduling is explicitly allowed

Claude's native scheduling tools are allow-listed so unattended sessions can
create future work without prompting under `defaultMode = "dontAsk"`:

- `CronCreate`
- `ScheduleWakeup`
- `Skill(schedule)`

This does not broaden shell execution or change the existing deny list. The
native scheduling tools are preferred over long `sleep` calls, which remain
subject to the tooling policy.

### WebSearch is allowed but domain-restricted (a hook, not a rule)

`WebSearch` is in the allow list, so it works under `dontAsk` — but WebSearch
permission rules take **no specifier** (`WebSearch` bare is the only form; no
domain filter, no wildcards — `WebSearch(domain:…)` is rejected). "No arbitrary
websearch" therefore has to be enforced outside the permission system, and it
is, from the single `webSearchDomains` list in `claude-permissions-data.nix`:

- **A PreToolUse hook** (`claude-websearch-hook`, written by
  `claude-permissions.nix`) refuses any WebSearch call whose `allowed_domains`
  is not a non-empty subset of the whitelist, and refuses `blocked_domains`
  entirely (negative scoping can't reconcile with a whitelist). A hook deny
  beats the allow rule, so unscoped or off-list searches fail closed.
- **`WebFetch(domain:…)` allow rules** for the same domains are the only pages
  Claude may read. WebSearch returns titles/URLs only; WebFetch is how it reads
  a result page, so this closes the second half of the boundary.

A whitelist change must update **both** — the hook (which bakes the list in) and
the WebFetch allow rules. The verifier checks the allow rules exist, so a change
that forgets them is caught as drift. The whitelist is deliberately small
(nixos.org, nix.dev, discourse.nixos.org, github.com, stackoverflow.com,
code.claude.com); widen it in the data module when the agent legitimately needs
another source.
