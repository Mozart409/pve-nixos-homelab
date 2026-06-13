# Tier 2 Plan — Sandbox hermes terminal/code in rootless Podman

Status: **proposal for review** (nothing implemented). Author: pairing session 2026-06-14.

## 1. Goal & threat model

We set `services.hermes-agent.settings.approvals.mode = "off"` so the headless API
server (Open WebUI gateway) stops blocking on un-answerable approval prompts. That
removes the only guard between an LLM turn and arbitrary shell as the `hermes` user.

The agent has the full prompt-injection "lethal trifecta":

- **Untrusted content** — `web` search/extract + the Obsidian vault (notes anyone edits).
- **Private access** — `terminal`/`execute_code` as `hermes`; agenix secrets on disk;
  the Forgejo SSH deploy key; Tailscale identity; Home Assistant MCP.
- **Exfil path** — `web` + `terminal` (curl/ssh).

The API key on the gateway stops *unauthenticated strangers*; it does nothing against
injection riding in on content a legit session fetches.

**Tier 2 goal:** move `terminal` + `execute_code` (and, as a consequence, the file
tools) off the host into an ephemeral, rootless container per session, so injected
shell/code can only touch what we explicitly mount — not host secrets, not other VMs.

## 2. Key facts established from the Hermes source

(Source tree: `nix/store/lawm6pjwd80yi0flk6199ia18g5lqf1r-source`.)

1. `settings.terminal.backend` drives the terminal tool **and** `execute_code`
   (`code_execution_tool.py:19` — "Script runs inside the terminal backend").
2. The **file tools follow the same backend** — `file_tools.py:730` builds
   `ShellFileOperations(terminal_env)` with the same `env_type`. So switching to a
   container moves `read_file`/`write_file`/`search_files` **into the container**.
   → The Obsidian vault on the host is invisible unless bind-mounted back in.
3. Docker backend exposes arbitrary binds via `terminal.docker_volumes`
   (`docker.py:580`, list of `host:container` strings). Lists are JSON-encoded
   correctly through the config→env bridge (`gateway/run.py:1060`).
4. Apptainer backend (`singularity.py`) runs `--containall --no-home` and only binds
   credential files + skills dir read-only — **no arbitrary-bind config**. → cannot
   host the vault workflow without patching Hermes. **Rejected.**
5. Hermes has **native Podman support** (`docker.py` `find_docker`): resolution order
   is `HERMES_DOCKER_BINARY` env override → `docker` on PATH → `podman` on PATH.
   Podman supports every flag the backend uses (`--label`, `-v`, `--network`,
   `--storage-opt`, `--filter label=` for the orphan reaper).
6. Default image: `nikolaik/python-nodejs:python3.11-nodejs20` (has Python3, required
   for `execute_code` remote RPC). Container defaults: 1 CPU / 5 GB RAM / 50 GB disk,
   persistent per task, network ON.
7. The module **restricts** the service PATH (`nixosModules.nix`:
   `path = [pkg bash coreutils git] ++ extraPackages`) and sets `NoNewPrivileges=true`,
   `ProtectSystem=strict`, `ReadWritePaths=[stateDir workingDirectory]`, `PrivateTmp`.

## 3. Architecture

```
                    hermes VM (NixOS)
  ┌───────────────────────────────────────────────────────────┐
  │ hermes-agent (systemd service, User=hermes)                │
  │   - LLM turn, web toolset, memory  → run on host           │
  │   - terminal / execute_code / file tools → podman ─────┐   │
  │                                                        │   │
  │   HERMES_DOCKER_BINARY = .../bin/podman                │   │
  └────────────────────────────────────────────────────────┼──┘
                                                            ▼
            ┌──────────────── rootless podman ─────────────────┐
            │ ephemeral container (nikolaik/python-nodejs)     │
            │   bind: /var/lib/hermes/workspace/vault (rw)     │
            │   bind: gitconfig (ro)  — commit identity        │
            │   NO ssh key.  NO agenix secrets.  NO host fs.    │
            │   agent: edit notes, `git add && git commit -m …` │
            └──────────────────────────────────────────────────┘
                                  │ commit advances .git/logs/HEAD
                                  ▼
  ┌───────────────────────────────────────────────────────────┐
  │ hermes-vault-sync (host oneshot, has the SSH key)          │
  │   git pull --rebase --autostash ; git push                 │
  │   triggered by: path unit on .git/logs/HEAD  (outbound)    │
  │               + slow timer                    (inbound)    │
  └───────────────────────────────────────────────────────────┘
```

**Why this shape:** a `git commit` is purely local (no key, no network); push/pull need
the Forgejo deploy key + `forgejo:2222`. Putting push/pull in the jail would re-mount
the deploy key into reach of injected code — defeating the jail. So the agent **commits
on-demand with a meaningful message** (in-jail, keyless); the **host pushes** (key stays
host-side). With rootless podman, container-root maps to host-`hermes`, so committed
files are owned by `hermes` on the host and `safe.directory` is a non-issue.

This also answers the commit-message question: the old timer wrote
`hermes: sync <ISO-timestamp>` (`configuration.nix:72`) — content-free. After this
change **the host service never commits**; the agent authors every commit
("add eggs + milk to grocery list"). The host service only moves commits.

## 4. The one hard problem: rootless Podman vs `NoNewPrivileges=true`

Rootless Podman maps multiple UIDs via the **setuid** helpers `newuidmap`/`newgidmap`.
`NoNewPrivileges=true` (set by the hermes module) makes the kernel ignore the setuid
bit → `newuidmap` can't write the uid_map → rootless podman fails to build the user
namespace. This is the central implementation risk. Resolutions, pick one:

- **(A) Relax NNP on the agent service** — `systemd.services.hermes-agent.serviceConfig.NoNewPrivileges = lib.mkForce false;`
  Simplest. Defensible because the *risky* work (shell/code) now runs jailed in a
  container; NNP on the host agent process matters far less once that's true. Cost: a
  Tier-1 hardening regression on the host process. **Recommended for the homelab.**
- **(B) Rootless Podman as a user service + socket** — `loginctl enable-linger hermes`,
  run podman's user socket, point Hermes at it (`HERMES_DOCKER_BINARY` wrapper or
  `DOCKER_HOST=unix:///run/user/<uid>/podman/podman.sock`). Keeps NNP. More moving
  parts; `XDG_RUNTIME_DIR` / lingering for a `isSystemUser` account is fiddly.

> First-deploy reality check: rootless podman for a `isSystemUser` system service is the
> least-trodden path here. Expect 1–2 iterations on storage/runroot/XDG_RUNTIME_DIR and
> the NNP issue above. Budget a debugging pass.

## 5. Concrete changes

### 5.1 Enable rootless Podman + subuid/subgid
```nix
virtualisation.podman.enable = true;            # rootless, daemonless

users.users.hermes = {
  subUidRanges = [{ startUid = 100000; count = 65536; }];
  subGidRanges = [{ startGid = 100000; count = 65536; }];
};
```
Ensure rootless storage/runroot land under the (writable) stateDir, e.g. via
`environment.HOME`-relative `~/.local/share/containers` (stateDir is in `ReadWritePaths`),
or set `CONTAINERS_STORAGE_CONF`/`XDG_RUNTIME_DIR` explicitly. Verify on first deploy.

### 5.2 Point Hermes at podman + switch the backend
```nix
services.hermes-agent.environment = {
  # ...existing...
  HERMES_DOCKER_BINARY = "${pkgs.podman}/bin/podman";
};

services.hermes-agent.settings.terminal = {
  backend = "docker";              # find_docker → podman via HERMES_DOCKER_BINARY
  timeout = 180;
  container_persistent = true;     # reuse warm container per task
  docker_image = "nikolaik/python-nodejs:python3.11-nodejs20";  # has python3 + git*
  docker_volumes = [
    "${vaultPath}:${vaultPath}"    # vault rw, same path → OBSIDIAN_VAULT_PATH resolves
    "${hermesHome}/.gitconfig:/root/.gitconfig:ro"  # commit identity in-jail
  ];
};
```
\* **Verify the image actually ships `git`.** If not, bake a tiny image
`FROM nikolaik/... RUN apt-get update && apt-get install -y git` and point
`docker_image` at it (per-container `apt-get` won't persist on ephemeral runs).

### 5.3 Sync redesign — agent commits, host moves
- **Keep** `hermes-vault-git-setup` (writes host `~/.ssh/config` + `~/.gitconfig`).
- **Rewrite** `hermes-vault-sync` to **pull+push only, never commit**:
  `git pull --rebase --autostash` then `git push` (keep clone-on-first-run).
- **Add** `systemd.paths.hermes-vault-sync` watching `${vaultPath}/.git/logs/HEAD`
  (`PathModified`) → starts `hermes-vault-sync.service` on each agent commit (outbound).
- **Inbound** (your Obsidian edits → agent): keep a *pull* trigger. Either a slow timer
  (e.g. `OnUnitActiveSec = "5min"`, pull-only now so **no junk commits**), or a
  sentinel-file path unit the agent can touch to request a refresh. Recommend the slow
  timer for simplicity.

### 5.4 SOUL.md guidance update
- Add: "After editing vault notes, save them with
  `git -C \"$OBSIDIAN_VAULT_PATH\" add -A && git commit -m \"<concise change>\"` via the
  terminal. This is local; the host pushes automatically within seconds."
- Remove the existing "you may run `git -C … pull --rebase` via the terminal" line — it
  needs the SSH key + network, which the jail intentionally lacks; the host handles pull.

## 6. What this contains vs. what it does NOT

Contained after Tier 2:
- Injected shell/code can read/write **only** the vault bind — not agenix age files, not
  `~/.ssh` (deploy key), not other hosts' filesystems, not the host process table.
- The Forgejo deploy key never enters the jail.

Still exposed (be honest):
- The `web` toolset runs in the **host** agent process and always has internet, so this
  is host-filesystem/process isolation, **not** a network airgap. Container network is
  left ON so in-jail `pip`/`curl`/`git commit` work. Exfil via `web` is unchanged.
- Worst case in-jail injection can still corrupt the vault contents (then auto-pushed).
  Mitigation is git history on Forgejo, not prevention.
- Memory store, MCP (Home Assistant) calls run host-side.

## 7. Verification

1. `just nixos-check` && `just fmt`.
2. Deploy; `systemctl restart hermes-agent` (config-only changes may not restart it).
3. `sudo -u hermes HERMES_DOCKER_BINARY=… podman info` — rootless stack healthy.
4. Via Open WebUI: ask the agent to run `id && hostname && ls /` — confirm it reports the
   **container** (image hostname, no host paths), and `cat /var/lib/hermes/.ssh/*`
   **fails** (not mounted) while the vault path lists.
5. Ask it to add a line to a vault note + commit; confirm host `journalctl -u
   hermes-vault-sync` shows a push with the agent's message, and Forgejo shows it.
6. Edit a note in Obsidian; confirm the agent sees it after the next pull.

## 8. Rollback

Single-knob: set `settings.terminal.backend = "local"` and redeploy — file/terminal
tools return to the host. Podman enablement and the sync redesign are independent and can
stay. (Approvals stay `off` regardless.)

## 9. Open decisions for you

1. **NNP resolution:** (A) relax `NoNewPrivileges` on the agent service [recommended,
   simple] vs (B) rootless podman user-service + socket [keeps NNP, more setup].
2. **Inbound sync:** slow pull-only timer [recommended] vs sentinel-file path unit for
   fully on-demand pulls.
3. **Container image:** stock `nikolaik/python-nodejs` if it has `git`, else a tiny
   custom image adding git — confirm before we commit to one.
4. **Container network:** leave ON (pip/curl/commit work) vs `--network=none` for the
   jail (stronger, but breaks in-jail package installs; not currently a simple config
   knob in this path — would need wiring).
```
