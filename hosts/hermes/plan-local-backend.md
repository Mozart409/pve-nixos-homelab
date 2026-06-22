# Plan: replace the rootless-podman sandbox with the `local` terminal backend

**Status:** draft for discussion
**Goal:** stop the `execute_code` / terminal / file-tool backend from wedging on every
deploy and on `hermes-agent` restarts, by removing the rootless-podman jail entirely and
running the agent's tools directly on the host (`terminal.backend = "local"`), confined by
the systemd unit sandbox the module already ships.

---

## 1. Why

`hosts/hermes/configuration.nix` carries a large pile of podman workarounds (stale
`pause.pid` reaping, runroot pinning, cgroup-manager forcing, `XDG_RUNTIME_DIR` pinning,
`Delegate`/`RuntimeDirectory`, a 210 s drain, `NoNewPrivileges` override, sub-UID/GID
ranges). Every one is a symptom of the same root cause: **rootless podman keeps mutable
runtime state (libpod DB, runroot, pause process, a *persistent* container) that gets
corrupted whenever the unit is killed mid-operation — which is exactly what a deploy
(stop → start) or restart does.** It is a losing fight against the design.

## 2. What the investigation established (authoritative, from the module source)

Source: `hermes-agent` flake input, `nix/nixosModules.nix` + `tools/terminal_tool.py`
(`github:NousResearch/hermes-agent` PR 49431, agent 0.17.0).

1. **`local` is a first-class backend and is in fact the module default.**
   `tools/terminal_tool.py`: `env_type` ∈ `{local, docker, ssh, singularity, modal,
   daytona}`; only `{docker, singularity, modal, daytona}` are containerized. `"local"`
   is documented as *"Execute directly on the host machine (default, fastest)."*
   `nix/nixosModules.nix:274` sets `terminal.backend = "local"` as the module default —
   **our config overrides it to `"docker"`. Switching to `local` is reverting to default,
   not inventing config.**

2. **The file tools containerize only for docker.**
   `tools/file_tools.py:412`: `if config.get("env_type") == "docker"`. With `local`,
   `file` / `terminal` / `code_execution` all run as the **`hermes` service user directly
   on the VM** — no podman, no libpod DB, no runroot, nothing to wedge.

3. **The module already hardens the native unit** (`nix/nixosModules.nix:910-918`):
   ```nix
   NoNewPrivileges = true;
   ProtectSystem  = "strict";
   ProtectHome    = false;
   ReadWritePaths = [ cfg.stateDir cfg.workingDirectory ];
   PrivateTmp     = true;
   ```
   So most of the confinement I'd otherwise add is already present. Our config currently
   *weakens* it with `NoNewPrivileges = lib.mkForce false` (needed only for podman's setuid
   `newuidmap`). Dropping that override **restores `NoNewPrivileges = true` for free.**

4. **`hermes` is already its own dedicated Proxmox VM** (`iac/main.tf` → `hermes_vm`,
   id 4334 = 192.168.2.155). The agent already has VM-level isolation from the rest of the
   homelab; the podman jail was only ever a *second, in-VM* layer.

5. **Native-mode PATH for the tools** (`nix/nixosModules.nix:921-926`):
   `path = [ effectivePackage bash coreutils git ] ++ cfg.extraPackages`.
   Under the docker backend, `execute_code`/`terminal` ran inside the
   `nikolaik/python-nodejs` image (python3 + node + git). **Under `local` they run with the
   host service PATH instead** — see §4, this is the one real new requirement.

## 3. Security trade-off — read this before approving

Switching to `local` changes the in-VM isolation model from "agent tools run in a
container that bind-mounts only the vault" to "agent tools run as the `hermes` uid,
confined by the systemd unit sandbox." Two concrete consequences:

- **The agent can read its own provider credentials.** The module does **not** use systemd
  `EnvironmentFile`; the activation script bakes `cfg.environment` + every
  `environmentFiles` entry into `$HERMES_HOME/.env` (`nix/nixosModules.nix:832-846`,
  mode 0640, owner `hermes`). That file lives under `stateDir`, which is in
  `ReadWritePaths`. So under `local`, the agent's own `file`/`terminal` tools can
  `cat ~/.hermes/.env` and read **DEEPSEEK_API_KEY, OPENCODE_ZEN key, the API-server key,
  and AXON_GATEWAY_TOKEN**. Under the docker backend those were *not* in the container, so
  the tools could not reach them. **This is a genuine new exposure.**
  - Severity: moderate. These are the agent's *own* operating credentials — it already
    uses them on every call; the new risk is that a prompt-injected agent could exfiltrate
    them rather than merely use them. They are rotatable.
  - It cannot be closed while keeping `local`: the agent process reads `.env` at startup
    and the tools share its uid + mount namespace, so no file-perm or `InaccessiblePaths`
    split is possible.

- **The Forgejo deploy key stays protected.** It is *not* in `.env` — it's a file
  referenced by ssh at `/run/agenix/hermes-forgejo-ssh` (owner `hermes`, 0400). We block it
  from the agent with `InaccessiblePaths = [ "/run/agenix" ]` on the agent unit (the agent
  never reads `/run/agenix` at runtime — secrets come from `.env`; the separate
  `hermes-vault-sync.service` keeps its access because it doesn't get this restriction).
  This is the highest-value secret (write access to the KB git repo) and it remains out of
  reach.

- **The "approval" safety floor changes.** Today `approvals.mode = "off"` is justified by
  "the container is the sandbox." With the container gone, the floor for injected
  shell/code becomes **the systemd sandbox (`ProtectSystem=strict` caps writes to
  `stateDir`/workspace + `PrivateTmp`) plus Hermes' non-bypassable hardline rules
  (`rm -rf /`, fork bombs, raw-disk writes, `sudo -S`).** We keep `approvals.mode = "off"`
  because the Open WebUI gateway can't answer an interactive approval prompt anyway (the
  original reason it's off). Net: blast radius of a destructive command is bounded to the
  vault + agent state, on a disposable VM.

**Bottom line:** we trade a fragile, stateful container for stateless kernel-namespace
confinement, accepting that the agent's *own* provider keys + MCP token become readable by
its tools, while the higher-value Forgejo write-key and the rest of the host stay
protected. Given the dedicated VM, this is a modest, reversible downgrade.

## 4. The one new requirement: host toolchain for the tools

With `local`, `execute_code`/`terminal` use the service PATH, not the python-nodejs image.
The module only puts `bash coreutils git` there. We must provision whatever the agent's
code/terminal tools are expected to use, via `services.hermes-agent.extraPackages`
(appended to the unit `path`). Proposed minimum to match the old image:

```nix
services.hermes-agent.extraPackages = with pkgs; [
  python3 nodejs curl jq gnugrep gnused gawk findutils
];
```
**Open question for discussion (Q1):** how rich should this be? Match the old image
(python3 + node20) or keep it lean? `execute_code`'s tool-RPC python may be provided by the
hermes runtime itself; needs a quick functional check after switch.

## 5. Concrete edits to `hosts/hermes/configuration.nix`

### Remove (podman machinery)
- `let` bindings + their comment blocks: `podmanRunRoot`, `podmanStorageConf`,
  `podmanContainersConf`, `podmanStorageSetup`, `podmanPauseGuard` (current lines ~95-191).
- `environment.HERMES_DOCKER_BINARY` (line 288).
- `virtualisation.podman.enable = true;` (line 611).
- `users.users.hermes` `subUidRanges` / `subGidRanges` block (lines 616-642) — no userns
  mapping needed without rootless podman.
- In `systemd.services.hermes-agent`:
  - drop `pkgs.podman` and `"/run/wrappers"` from `path` (line 552).
  - drop `environment.XDG_RUNTIME_DIR` (line 566).
  - drop from `serviceConfig`: `Delegate`, `RuntimeDirectory`, `RuntimeDirectoryMode`,
    `RuntimeDirectoryPreserve`, `ExecStartPre`, and `NoNewPrivileges = lib.mkForce false`.

### Change
- `settings.terminal` (lines 428-444) → just:
  ```nix
  terminal = {
    backend = "local";
    timeout = 180;
  };
  ```
  (drops `docker_image`, `docker_volumes`, `docker_env`, `container_persistent`,
  `docker_env.OBSIDIAN_VAULT_PATH` — the vault is now a plain host path the tools see
  directly; `OBSIDIAN_VAULT_PATH` stays set in `environment`.)

### Add
- `serviceConfig.InaccessiblePaths = [ "/run/agenix" ];` on `hermes-agent` (blocks the
  Forgejo key; safe because the agent reads secrets from `.env`, not `/run/agenix`).
- `services.hermes-agent.extraPackages` per §4.
- **Open question (Q2):** keep `TimeoutStopSec = 210`? Its original job was preventing
  mid-drain SIGKILL from orphaning podman helpers. With no podman there are no orphans, but
  the agent still drains up to 180 s, so 210 s still buys a clean shutdown. Cheap to keep;
  no longer load-bearing. Lean toward keeping (drop the `mkForce`, plain `= 210`).

### Keep unchanged
- Vault sync stack (`hermes-vault-git-setup`, `hermes-vault-sync` service/timer/path) and
  the `~/.ssh/config` + `~/.gitconfig` install — the agent's in-host `git commit` uses
  `~/.gitconfig` directly now (no bind-mount needed); the key-bearing push/pull stays in
  the separate sync service.
- `toolsets` / `platform_toolsets`, `documents`, `mcpServers`, `memory`, web/searxng,
  Caddy, firewall.

## 6. Verification

1. `just fmt` then `just nixos-check`.
2. `just colmena-diff-host hermes` to eyeball the unit/service delta.
3. Deploy; then on the host (`amadeus@192.168.2.155`, sudo):
   - `systemctl status hermes-agent` clean; no `ExecStartPre`/podman units referenced.
   - From Open WebUI: `execute_code` runs python; `terminal` runs `ls`/`git`; a vault edit
     + `git -C "$OBSIDIAN_VAULT_PATH" commit` fires `hermes-vault-sync` and pushes.
   - **Confirm the protection:** as the agent, `cat /run/agenix/hermes-forgejo-ssh` must
     fail (InaccessiblePaths). `cat ~/.hermes/.env` *will* succeed — that's the accepted
     trade-off, not a bug.
4. **The real test:** redeploy twice and restart `hermes-agent` a few times; `execute_code`
   must keep working with zero manual intervention (the whole point).

## 7. Rollback

Single-file revert (`git checkout` `hosts/hermes/configuration.nix`) + redeploy restores
the podman backend. No data migration: the vault and `stateDir` are untouched; only the
tool execution path changes. The podman image storage under
`~/.local/share/containers` is left in place (harmless) and can be GC'd later.

## 8. Decisions needed before implementing

- **Q1 — toolchain breadth** in `extraPackages` (match old python+node image vs lean).
- **Q2 — keep `TimeoutStopSec = 210`?** (recommend yes, as plain value.)
- **Q3 — is the `.env` provider-key exposure (§3) acceptable?** If not, the only real
  alternative is staying on a container backend (back to the fragility) — there is no
  middle option under `local`.
- **Q4 — also clean up the AGENTS.md "Common Pitfalls" podman sections** once this lands?
  They become obsolete/misleading after the switch.
