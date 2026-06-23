# Plan: replace the rootless-podman sandbox with the `local` terminal backend

**Status:** ON HOLD — trying a cheaper fix first (ephemeral podman; see §9–§11). This
`local` migration stays the documented fallback if that experiment doesn't hold.
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

---

## 9. Alternatives considered (research, 2026-06-22)

The choice is **not** binary (`local` vs. fragile podman). The `hermes-agent` module exposes
six backends (`local, docker, ssh, singularity, modal, daytona`) which — with the systemd/uid
toolbox — give several points on an **isolation-strength vs. operational-weight** curve. The
thing `local` trades away (the agent's own `.env` provider keys + the MCP token become
readable by the tool sandbox; see §3) can be bought back more cheaply than "rootful docker."

| Backend / approach | Isolation | Survives deploys | Keeps `.env`+Forgejo key out of tool sandbox | Ops weight |
|---|---|---|---|---|
| `local` (this plan) | systemd unit sandbox only | yes | ✗ tools read `.env` as the service uid | lowest |
| **ephemeral podman** (`container_persistent=false`) | container (ns) | much improved | ✓ | ~zero (1-line) — **chosen first** |
| `ssh` → localhost as a separate unpriv. user | uid perms only | yes | ✓ (the two key files, by mode) | low–med |
| `singularity` / apptainer | container (ns) | likely | ✓ | low–med |
| `ssh` → dedicated sandbox VM / LXC / nspawn | full host / ns | yes | ✓✓ (no secrets present there) | med–high |
| rootful docker (`dockerd`) | full ns | yes | ✓ | med (privileged daemon) |
| modal / daytona | cloud VM | yes | ✓ | rejected — external, data leaves LAN |

Notes on the non-obvious options:

- **ephemeral podman** (chosen, see §10): most of podman's fragility is the *persistent*
  container — a long-lived libpod record holding storage/userns locks that corrupt on a
  mid-drain SIGKILL. `container_persistent = false` makes each call a fresh `--rm` container
  with almost nothing to carry across restarts, *without* abandoning containerization, so the
  secret isolation `local` would sacrifice is preserved. One-line change; try first.

- **`ssh` → localhost as a separate unprivileged user**: the sleeper option. The `ssh`
  backend runs tools over ssh on a target, and that target can be `tooluser@localhost` on
  *this* VM, reusing the running sshd (no new daemon, no container state → as robust as
  `local`). But the tools run as a *different uid* that can't read `/var/lib/hermes/.env`
  (0640 hermes) or the Forgejo key (0400 hermes) — recovering exactly the isolation `local`
  gives up. The module forces `local` to run tools as the *service* user; `ssh`-to-localhost
  is the module-native way to insert a uid boundary `local` won't. Vault → shared-group dir
  (`vault` group, `hermes`+`tooluser`, SGID); Forgejo key stays `hermes`-only so `tooluser`
  commits locally and `hermes-vault-sync` (as hermes) still pushes — current split preserved.
  De-risk first: confirm the module's `ssh` backend takes localhost+alt-user with a
  persistent connection (ControlMaster, for latency), that `execute_code`'s RPC works over
  it, and that file tools run on the target. Isolation = uid perms only (tooluser still sees
  world-readable files, host services, the LAN).

- **`singularity` / apptainer**: daemonless containerization; the normal model is ephemeral
  `exec` of a SIF image — far less persistent bookkeeping than podman's libpod DB / pause.pid.
  Module-native, keeps isolation. Caveat: unprivileged apptainer still uses the same
  user-namespace machinery, so *plausibly* immune to podman's stateful-corruption class but
  not guaranteed.

- **`ssh` → dedicated sandbox host** (2nd VM, or an LXC / `systemd-nspawn` here): tools run
  somewhere holding *no* secrets; injected code lands with nothing to steal and no path back.
  Strongest practical isolation, module-native. Cost: a 2nd host + the vault must live there
  (NFS/bind or relocate the clone).

- **rootful docker** (`dockerd`): full namespace isolation + daemon-managed robustness +
  secrets stay out, at the cost of a privileged daemon + image GC. The "middle option"
  §3/Q3 implied didn't exist.

- **modal / daytona**: rejected — external cloud sandboxes, data leaves the LAN.

## 10. Decision: try ephemeral podman first (2026-06-22)

Picked the cheapest experiment that *keeps the secret isolation* before committing to the
`local` rewrite. Applied to `hosts/hermes/configuration.nix`:

1. `settings.terminal.container_persistent = false` — ephemeral per-call containers.
2. Dropped `serviceConfig.RuntimeDirectoryPreserve = "yes"` (was there solely to preserve the
   *persistent* container's runtime state across restarts). With it gone, systemd wipes +
   recreates `/run/hermes-podman` on every stop/start → the runroot is self-cleaning and a
   stale `pause.pid` can no longer survive a restart by construction.

**Deliberately KEPT** — these are per-`podman run` determinism, *not* persistent-container
plumbing; removing any reintroduces the original, persistence-independent wedges:
runroot/graphroot pin (`storage.conf`), cgroupfs manager + `tmp_dir` (`containers.conf`),
`XDG_RUNTIME_DIR` pin, `Delegate`, `RuntimeDirectory`, `NoNewPrivileges=false` (setuid
`newuidmap`), sub-UID/GID ranges, `TimeoutStopSec=210` (clean agent drain).

**One judgment call:** the `podmanPauseGuard` ExecStartPre is *kept* as a safety net for the
now-rare mid-call SIGKILL orphan, and as observability — its log lines reveal whether orphans
still occur under ephemeral. Its stale-`pause.pid` job is now redundant (fresh runroot).
Remove it once ephemeral is proven if you want it leaner.

**Hypothesis:** with no persistent container to corrupt, `execute_code`/terminal/file keep
working across repeated deploys + `systemctl restart hermes-agent` with zero manual fixes.

**How to evaluate:** redeploy twice, `systemctl restart hermes-agent` a few times, and after
each confirm from Open WebUI that `execute_code` runs python + `terminal` runs `ls`/`git`.
Watch `journalctl -u hermes-agent` for the pause-guard reaping anything (it shouldn't, if the
hypothesis holds). Per-call container startup adds latency vs. the persistent container, and
in-session shell state no longer persists between calls — confirm neither breaks a workflow.

**If it doesn't hold:** fall back along §9 — next cheapest that keeps isolation is the
`ssh`→localhost-as-`tooluser` backend; then apptainer; then the full `local` rewrite (§11)
if the `.env` exposure is deemed acceptable.

## 11. If we fall back to the `local` rewrite: gaps to fix first

From reviewing this plan against the live `configuration.nix`:

- **Stale comments become wrong.** The `approvals.mode = "off"` justification (the "sandbox
  is the podman jail" paragraph) and the `settings.terminal` comment block both describe a
  jail that no longer exists under `local` — rewrite them, not just the code.
- **`InaccessiblePaths` is the *sole* guard for the Forgejo key under `local`.** The agent
  runs as `hermes` with `~/.ssh/config` pointing `IdentityFile` at the key, so only
  `InaccessiblePaths` stops it from reading + pushing. `/run/agenix` is an **agenix symlink**
  to `/run/agenix.d/<gen>` — blocking the symlink may not mask the target; be ready to block
  `/run/agenix.d`. The §6 `cat` test catches a miss. (It only meaningfully protects the
  Forgejo key; the other four secrets are in `.env` regardless.)
- **Add systemd resource caps** (`TasksMax`, `MemoryMax`/`MemoryHigh`, `LimitNPROC`): tools
  move into the unit cgroup and neither backend had caps. `ProtectSystem=strict` bounds
  *writes*, not CPU/mem/pids.
- **Re-verify the cited module source line numbers** against the pinned `hermes-agent` rev
  before trusting them — the whole plan rests on them.
- **Drop `pkgs.openssh` from the agent unit `path`** too (defense in depth — the agent has no
  legitimate ssh need and you're actively denying it the key).
- **Verified OK — don't re-investigate:** `OBSIDIAN_VAULT_PATH` is already a host path
  bind-mounted at the *same* path, so the switch needs no path translation; the `git commit`
  flow uses `~/.gitconfig` as `hermes` and works under `local`; the `.env` exposure is exactly
  the four secrets in `environmentFiles`; the Forgejo key is *not* in `.env`.

## 12. Ephemeral-podman experiment: result (2026-06-23)

Deployed `container_persistent = false` + the `RuntimeDirectoryPreserve` removal (§10) and
restarted/redeployed several times. **It wedged — but on a NEW failure variant I introduced,
not the persistent-container one.** Findings, all reproduced on-host (`amadeus@192.168.2.155`):

- **Symptom:** every `podman run` exits **125** with
  `unable to create a new pause process: ... open /run/hermes-podman/libpod/tmp/pause.pid:
  no such file or directory`. `execute_code`/`terminal` → "the Docker sandbox isn't working."
  It hit **63 s into a clean instance** (`NRestarts=0`), so it was NOT a restart-storm
  artifact — it's deterministic.

- **Root cause (a regression from §10):** the service pins
  `environment.XDG_RUNTIME_DIR = /run/hermes-podman`, so podman places its **per-user pause
  process** state at `$XDG/libpod/tmp/pause.pid`. That subtree used to survive across restarts
  via `RuntimeDirectoryPreserve = "yes"`; **removing it** made systemd wipe the runroot to a
  *bare* dir on every start, and podman does **not** reliably create `libpod/tmp` itself →
  pause-process setup fails. The pause process is **per-user, not per-container**, so
  `container_persistent` never touched this path — which is exactly why ephemeral didn't help.

- **Isolation (clean repros):** `podman run` WITH `XDG=/run/hermes-podman` → fails;
  WITHOUT XDG → works; WITH XDG **and** a pre-created `libpod/tmp` → works. So the missing
  subtree is the whole story.
  - Rejected "just drop the XDG pin": it only worked because `loginctl` shows `Linger = yes`
    and `/run/user/995` still exists on the box (contradicting the config's stated linger-off
    intent), so podman silently fell back to the logind dir. That's the exact logind coupling
    the XDG pin was added to remove — fragile, don't rely on it.

- **Fix applied + verified (kept ephemeral):** added `mkdir -p /run/hermes-podman/libpod/tmp`
  to the `podmanPauseGuard` ExecStartPre. Keeps BOTH the self-cleaning runroot (Preserve=no:
  no stale `pause.pid` can survive a restart) AND the XDG pin (no logind dependency). Post-
  deploy and post-`systemctl restart`, podman runs clean with the service XDG; subtree is
  recreated fresh on each (wiped) start. Agent `active`.

- **Correction — `container_persistent` was the WRONG knob (found 2026-06-23 via the live
  agent code).** `tools/environments/docker.py` has TWO independent settings:
  - `container_persistent` → `persistent_filesystem` (docker.py:1251/1271): only chooses
    bind-mount vs tmpfs for `/workspace`+`/root`. Does NOT touch the container lifecycle.
  - `docker_persist_across_processes` (docker.py:1279, **default TRUE**): the real one — keeps
    ONE `sleep infinity` container and **reuses it across Hermes processes/restarts** by label,
    running `podman start` on the stale one. After a mid-drain SIGKILL that record is corrupt
    and `podman start` returns **exit 125** ("Failed to start existing container … — falling
    back to a fresh container"). THIS is the persistent container the plan meant to remove.

  So `container_persistent = false` alone left the cross-restart sleeper in place (observed:
  one container reused for 2h+, plus a SIGTERM-killed `Exited (143)` record from 35h earlier).
  Fixed by adding **`terminal.docker_persist_across_processes = false`** → each agent process
  creates its own container and stop+rm's it on exit (docker.py:1236); no cross-restart reuse,
  so the corruption vector is gone. A built-in orphan reaper (`_maybe_reap_docker_orphans`,
  default on) plus our `podmanPauseGuard` mop up any container left by an unclean SIGKILL.
  Deployed + verified: live config shows both flags false, restart leaves no stale-reuse
  error, agent `active`.

- **Meta-conclusion (the reason this plan exists):** getting ephemeral to actually work took a
  pause-process subtree fix AND discovering the real persist knob — i.e. two more rounds of
  podman-specific archaeology, after stale `pause.pid` and runroot-DB mismatch. All from the
  same root: rootless podman's per-user runtime/pause-process state + cross-process container
  reuse + the elaborate pinning to make it deterministic. **Recommendation:** soak the now-
  correct ephemeral config (`container_persistent=false` + `docker_persist_across_processes=
  false`) to confirm the wedge is gone, but treat the whole saga as further evidence for
  migrating off rootless podman — `local` (this plan) or `ssh`→localhost (§9), neither of which
  has a per-user pause process, a runroot to pin, or a cross-process container to reuse.

- **Unrelated tension noticed:** `serviceConfig.TimeoutStopSec` is committed at `90` (commit
  `b46ca7e` "timeout back to 90s") while the inline comment still argues for `>=180+margin`.
  At 90 s systemd SIGKILLs the agent mid-drain (drain is up to 180 s), which is the documented
  orphan-creating behavior. Left as-is (deliberate commit) but flagged — the comment is now
  misleading and should be reconciled with whatever the intended value is.
