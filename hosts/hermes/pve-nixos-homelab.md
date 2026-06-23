# Plan: Hermes agent dev access to `pve-nixos-homelab`

Goal: let the Hermes agent (driven from Open WebUI on the phone) **clone, read,
edit, and commit** this homelab repo inside its podman sandbox, develop changes
on **feature branches**, and have a host-side service **push those branches** to
Forgejo. `main` is branch-protected, so the agent can never clobber it; the user
reviews the branch, opens a PR, and deploys (`colmena`) when home. The sandbox
also gains **`nix`** (via the host nix-daemon) so the agent can actually validate
flake changes (`nix flake check`, `just fmt`, `nix develop -c ...`).

This mirrors the existing Obsidian-vault plumbing in
`hosts/hermes/configuration.nix` (the `vault*` let-bindings + the
`hermes-vault-{git-setup,sync}` services / timer / path unit).

## Status / decisions

- [x] `hermes-bot` added as **Write** collaborator on `amadeus/pve-nixos-homelab`.
- [x] `main` **branch-protected** (direct pushes blocked → PRs only).
- [x] **Auto-PR skipped for now** — no Forgejo API token, no PR-creation logic.
      The host service only pushes the feature branch; the user opens the PR.
- Access reuses the **existing** `hermes-forgejo-ssh` key (same `hermes-bot`
  account, same `forgejo.homelab.local:2222` host the `~/.ssh/config` block
  already routes). **No new secret is required.**
- Cannot be deployed/tested until at the host (needs the machine + colmena).

## Key facts (verified)

- SSH remote: `ssh://forgejo@forgejo.homelab.local:2222/amadeus/pve-nixos-homelab.git`
  (port 2222, user `forgejo`; the existing `~/.ssh/config` Host block + the
  `hermes-forgejo-ssh` deploy key already cover this host).
- Forgejo HTTP (if ever needed): `https://forgejo.homelab.local` (step-ca cert,
  trusted on hermes via `modules/step-ca-trust.nix`). Not used while auto-PR is off.
- The token/key never enter the sandbox (host-side push only), same as the vault.

## Implementation steps

### 1. `hosts/hermes/configuration.nix` — new let-bindings (near the `vault*` block)

```nix
repoOwner    = "amadeus";
repoName     = "pve-nixos-homelab";
repoPath     = "${hermesHome}/workspace/pve-nixos-homelab"; # inside file-tool sandbox root
repoRemote   = "ssh://forgejo@forgejo.homelab.local:2222/${repoOwner}/${repoName}.git";
```

### 2. Reuse SSH/git config (no change to the `vaultSshConfig` Host block)

The `Host forgejo.homelab.local` block already applies to the repo remote.
**Add `repoPath` to `[safe] directory`** in `vaultGitConfig` (multiple `directory`
lines are allowed) so both the in-jail git and the host-side service trust the
checkout:

```
[safe]
  directory = ${vaultPath}
  directory = ${repoPath}
```

### 3. Host-side `hermes-repo-sync` script (push-only; mirrors `vaultSync`)

Runs as the `hermes` user. Logic:

- Pre-`mkdir -p ${repoPath}`; if `${repoPath}/.git` is absent, `git clone` into it
  (clone into an existing *empty* dir is allowed). On clone failure: log + `exit 0`
  (leaves an empty dir so the agent's bind-mount still succeeds; the timer retries).
- `cd ${repoPath}` then `git fetch origin --prune` (keeps `origin/main` fresh for
  the agent to branch from). On failure: `exit 0`.
- `branch=$(git rev-parse --abbrev-ref HEAD)`.
- If `branch` is `main`/`master`/`HEAD` (detached) → **do not push**; `exit 0`.
- `ahead=$(git rev-list --count origin/main..HEAD)`; if `ahead -eq 0` → `exit 0`.
- `git push -u origin "$branch"` (push to a protected `main` would be rejected by
  Forgejo anyway; this code never pushes `main`). Log on failure, `exit 0`.

Uses `GIT_SSH_COMMAND='${gitSshCmd}'` like the vault.

### 4. Sandbox gains `nix` (the `terminal` block, ~`configuration.nix:439-471`)

- `docker_volumes +=`:
  - `"${repoPath}:${repoPath}"` — the repo checkout, **read-write** (agent edits + commits).
  - `"/nix:/nix:ro"` — host store **and** the nix-daemon socket
    (`/nix/var/nix/daemon-socket/socket`, mode 0666 → connectable from the
    user-namespaced container).
- `docker_env +=`:
  - `HOMELAB_REPO_PATH = repoPath;`
  - `NIX_REMOTE = "daemon";` — builds run via the host daemon, so no writable
    store is needed in-jail; `nix flake check` / `nix build` work.
  - `NIX_CONFIG = "experimental-features = nix-command flakes";`
  - `NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";` (flake-input fetch over HTTPS)
  - `PATH` extended to include `${pkgs.nix}/bin` (keep the image's
    `/usr/local/bin` etc. so python/node for `execute_code` still resolve).
- Net effect: agent runs `cd "$HOMELAB_REPO_PATH" && nix develop -c just fmt` and
  `nix develop -c just nixos-check`; the repo's own devShell supplies
  `just`/`alejandra`/`tofu`. Sandbox network stays ON for flake-input fetches.

### 5. systemd units (mirror the vault's set)

- `systemd.services.hermes-repo-sync` — `Type=oneshot`, `User/Group=hermes`,
  `after = ["hermes-vault-git-setup.service" "network-online.target"]`,
  `requires = ["hermes-vault-git-setup.service"]`, `wantedBy multi-user.target`,
  `ExecStart = repoSync`.
- `systemd.timers.hermes-repo-sync` — `OnBootSec=2min`, `OnUnitActiveSec=5min`
  (keeps `origin/main` fresh + retries pending pushes).
- `systemd.paths.hermes-repo-sync` — `PathModified = "${repoPath}/.git/logs/HEAD"`
  → instant push the moment the agent commits.
- Extend `systemd.services.hermes-agent`: add `hermes-repo-sync.service` to
  `wants`/`after` (best-effort; the pre-`mkdir` guarantees the bind-mount target
  exists even if a clone is still pending).

### 6. SOUL.md — add a "Homelab config repo" section (in `documents`)

Instruct the agent:
- The repo is checked out at `$HOMELAB_REPO_PATH`; read it to understand/modify the homelab.
- **Never commit to `main`.** Per task: `git -C "$HOMELAB_REPO_PATH" fetch origin &&
  git -C "$HOMELAB_REPO_PATH" switch -c feat/<short-slug> origin/main`.
- Validate before committing: `cd "$HOMELAB_REPO_PATH" && nix develop -c just fmt &&
  nix develop -c just nixos-check`.
- Commit with a meaningful message. A host service pushes the branch automatically
  within seconds — you do **not** push, open PRs, merge, or deploy. The user
  reviews the branch, opens the PR, and deploys (`colmena`) when home.
- One feature branch per task; always start from a fresh `origin/main`.

### 7. `AGENTS.md` — short runbook entry

Document: collaborator + branch-protection setup, the nix-daemon sandbox mount,
and the feature-branch → manual-PR flow, so it's reproducible.

## Security note (deliberate jail widening)

Mounting `/nix` (ro) + the nix-daemon socket lets the sandbox read the entire host
store (already world-readable) and run builds via the host daemon (standard nix
multi-user model — **no host root**, no access to agenix secrets or the Forgejo
SSH key, which are not mounted). This is the minimal way to give the agent real
`nix`. Alternative considered & rejected for now: a custom `dockerTools` image
(more moving parts: image build + `podman load` orchestration).

## Deploy-time checks (can't validate offline)

1. In-sandbox: `nix --version`, then `nix flake check` in `$HOMELAB_REPO_PATH`
   (confirms the daemon-over-socket path works under the userns).
2. Confirm the nikolaik image still finds python/node after the `PATH` change
   (`execute_code` smoke test).
3. Agent commit on a `feat/*` branch → branch appears on Forgejo within seconds;
   a `main` commit attempt is rejected.

## Local verification before deploy

- `just fmt` (alejandra) on changed Nix.
- `just colmena-build-host hermes` (or `nix flake check`) to catch eval/build errors.
