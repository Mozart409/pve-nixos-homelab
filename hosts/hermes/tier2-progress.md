# Tier 2 deployment — progress & handoff (resume here)

Last worked: 2026-06-14 (late). Companion to `tier2-sandbox-plan.md`.

## TL;DR

The infrastructure side is **done and verified**. Rootless Podman works for the
`hermes` user, the agent's container backend is wired up, and all the Nix plumbing
bugs are fixed. The **only remaining blocker is the agent itself refusing to call
its tools because of a STALE MEMORY** — not a backend failure. Plan for tomorrow:
clear that memory, then force a real tool call to confirm the jail works
end-to-end. A VM reboot is queued (do it first).

## What's implemented (all in `hosts/hermes/configuration.nix`, uncommitted)

Decisions locked: **1A** (relax NNP) / **slow pull-only timer** / **stock image** /
**network ON**. See `tier2-sandbox-plan.md` §9.

1. `approvals.mode = "off"` — stops the headless API server blocking on
   un-answerable approval prompts (the original bug).
2. `terminal.backend = "docker"` (→ rootless podman) with:
   - `docker_image = "nikolaik/python-nodejs:python3.11-nodejs20"` (verified: ships
     git 2.47 / python 3.11 / node 20).
   - `docker_volumes`: vault `${vaultPath}:${vaultPath}` (rw) + host gitconfig ro.
   - `docker_env.OBSIDIAN_VAULT_PATH = vaultPath` (container doesn't inherit agent env).
   - `container_persistent = true`.
   This governs `terminal`, `execute_code`, AND the file tools (they share the backend).
3. `HERMES_DOCKER_BINARY = "${pkgs.podman}/bin/podman"` (env) — points find_docker at podman.
4. `virtualisation.podman.enable = true` + `users.users.hermes.subUid/subGidRanges`
   (100000/65536) + `linger = true`.
5. `NoNewPrivileges = lib.mkForce false` on the hermes-agent service (rootless podman
   needs setuid newuidmap; NNP would block it).
6. Service PATH extended: `path = [git openssh podman "/run/wrappers"]` — the
   `"/run/wrappers"` entry is what puts the setuid `newuidmap`/`newgidmap` wrappers
   on PATH. NB: list the PARENT dir; the `path` option appends `/bin`, so
   `"/run/wrappers/bin"` would wrongly become `/run/wrappers/bin/bin`.
7. Sync redesign: `hermes-vault-sync` no longer commits (pull --rebase --autostash +
   push only); `systemd.paths.hermes-vault-sync` pushes on every agent commit
   (watches `.git/logs/HEAD`); timer slowed to 5 min, pull-only (no junk commits).
8. SOUL.md: agent commits its own vault edits with meaningful messages; the
   impossible in-jail `git pull` instruction removed.

## What's verified working

- `sudo -u hermes -H podman info` / `run` / `version`: rootless stack healthy,
  idmaps correct (container-root → host-hermes), btrfs+overlay storage, image pulls
  and runs (`uid=0`, Debian trixie).
- Service PATH now contains the correct `/run/wrappers/bin`; `newuidmap` setuid
  wrapper present; `podman version` succeeds as the hermes user.
- In-jail commit flow tested standalone (identity from mounted gitconfig,
  `safe.directory`, `$OBSIDIAN_VAULT_PATH`, `.git/logs/HEAD` trigger, host-visible
  result owned by hermes).
- `nix flake check` (`just nixos-check`) passes; config evals to a full system
  derivation.

## The remaining blocker (do this first tomorrow)

The agent, via Open WebUI, refuses to run `id`/`hostname`/`ls`/etc. It is NOT
hitting a backend error anymore — it quotes a stale **holographic memory**:

> "The terminal tool is not available in this channel — only CLI has it.
>  Subprocess calls via execute_code require per-call approval which may not be
>  visible through Open WebUI."

That note was written during the approval-guard era and is now false. The agent
reads it and short-circuits without ever calling the tools.

### Fix steps (tomorrow, after reboot)

1. **Reboot the VM** (queued) and `sudo systemctl status hermes-agent` (it had one
   crash-loop entry `status=1/FAILURE` in the logs — confirm it's healthy post-reboot).
2. **Clear the stale memory.** Holographic store is SQLite FTS5 at
   `/var/lib/hermes/.hermes/memory_store.db`. Either:
   - Ask the agent (it has the `memory` toolset) to delete/correct the note about
     terminal/execute_code availability, or
   - Inspect/prune directly:
     `sudo -u hermes sqlite3 /var/lib/hermes/.hermes/memory_store.db "select rowid,* from <table> where <text> like '%terminal tool is not available%';"`
     (find the table first: `.tables` / `.schema`). Delete the offending row.
   - Nuclear option if it's only noise: stop the service, move the db aside, restart
     (loses all learned memory). Note `plugins.hermes-memory-store.auto_extract = true`
     means it re-extracts facts at session end — so re-correct, don't just delete, or
     it may relearn the wrong thing from old transcripts.
3. **Force a real call** through Open WebUI: explicitly tell it
   "use the execute_code tool to run `id` — do not consult memory, just call it."
   If it runs and returns `uid=0` + a container hostname, the jail is LIVE.
4. Then the acceptance checks: `cat /var/lib/hermes/.ssh/*` must FAIL inside the
   jail; add+commit a vault note and confirm `journalctl -u hermes-vault-sync` shows
   a push with the agent's message.

## Still UNVERIFIED (watch for these tomorrow)

- **Actual container RUN from inside the hardened service.** We confirmed
  `podman version` (exercises userns/newuidmap) but not a full `podman run` launched
  by the hermes-agent service under its sandbox (PrivateTmp etc.). Most likely fine.
  If `execute_code` now gets past newuidmap but fails at **cgroup/dbus on container
  creation**, that's the linger side-effect (podman switched to the systemd cgroup
  manager, which a system service can't always reach). Fixes, if needed:
  - force cgroupfs (containers.conf `[engine] cgroup_manager="cgroupfs"`), or
  - set `XDG_RUNTIME_DIR=/run/user/995` + pin `users.users.hermes.uid = 995`.
- **Is the `terminal` tool actually gated on the API-server platform**, separate from
  the agent's memory excuse? Unknown. `execute_code` is definitely exposed via the API
  server (the original bug was about it). If `execute_code` works but `terminal`
  genuinely isn't surfaced over the API server, investigate
  `gateway/platforms/api_server.py` tool exposure / platform toolset filtering. Not a
  blocker — execute_code satisfies "run commands via Open WebUI".

## Deploy / test command crib

```bash
colmena apply --on hermes        # or: just colmena-apply-host hermes
sudo systemctl restart hermes-agent     # config-only changes may not restart it
journalctl -u hermes-agent -n 100 --no-pager | grep -iE 'podman|docker|newuidmap|cgroup|error'
# rootless sanity as the service user:
cd /tmp && sudo -u hermes -H podman info | grep -iE 'cgroupManager|runRoot|rootless'
```

## Housekeeping note

A harness/sandbox artifact bind-mounted `/dev/null` over `.gitmodules` (and
`.zshrc`/`.zprofile`/`.ripgreprc`) in the repo root, which breaks `nix flake`/colmena.
If `nixos-check` errors with a libgit2 `.gitmodules` parse/permission error, clear it:
`sudo umount .gitmodules && rm -f .gitmodules` (repeat for the others).

## Uncommitted files

- `hosts/hermes/configuration.nix` (all the above)
- `hosts/hermes/tier2-sandbox-plan.md` (design)
- `hosts/hermes/tier2-progress.md` (this file)

Nothing committed yet — left on the working tree for review/test before a branch+commit.
