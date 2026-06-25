---
name: homelab-config-repo
description: Develop changes to the pve-nixos-homelab NixOS/IaC config on a feature branch, validate them with nix, and commit. Use whenever the user asks you to change, add, or fix anything in this homelab's own configuration (hosts, modules, flake, secrets wiring, services). The host auto-pushes your branch; the user opens the PR and deploys.
platforms: [linux]
required_environment_variables:
  - HOMELAB_REPO_PATH
required_commands:
  - git
  - nix
---

# Homelab Config Repo

Use this skill when the user asks you to change the homelab's own NixOS/IaC
configuration (the `pve-nixos-homelab` repo) — e.g. edit a host, add a service,
tweak a module, fix the flake. This repo is *partially your own config* (it
defines the hermes host you run on).

## Where it is

The checkout is at the path in `HOMELAB_REPO_PATH` (default
`/var/lib/hermes/workspace/pve-nixos-homelab`). Use that absolute path. It is a
Nix flake; read its root `AGENTS.md` for conventions and the full `just` command
list.

## Hard rules (read first)

- **NEVER commit to `main`.** It is branch-protected on Forgejo and your push
  would be rejected. Always work on a feature branch.
- **NEVER push, open PRs, merge, or deploy.** You have neither the SSH key nor
  network to Forgejo inside the sandbox. A host service pushes your feature
  branch automatically within seconds of each commit. The user reviews the
  branch, opens the pull request, and deploys with `colmena` when at the host.
- **Never** run `git reset --hard`, `git push`, `git pull`, or force anything in
  this repo.

## Workflow (every task)

1. **Start from fresh `origin/main`** on a new branch named for the task:
   ```
   git -C "$HOMELAB_REPO_PATH" fetch origin
   git -C "$HOMELAB_REPO_PATH" switch -c feat/<short-slug> origin/main
   ```
   One branch per task. If the new task is unrelated to a previous one, start a
   brand-new branch from `origin/main` — do not stack on the old branch.

2. **Make the change** with your file tools (`read_file`, `write_file`, `patch`,
   `search_files`). Follow the repo's style: `alejandra` formatting, `camelCase`
   attrs, lowercase hostnames, relative local imports. Match surrounding code.

3. **Validate before committing** (run from inside the repo so the flake resolves):
   ```
   cd "$HOMELAB_REPO_PATH"
   nix develop -c just fmt          # alejandra formatting (from the dev shell)
   ```
   Then **evaluate only the host(s) you changed** — do NOT run the full
   `just nixos-check` / `nix flake check`. The full check evaluates all ~16 hosts
   at once and reliably gets OOM-killed (exit 137) on the host nix-daemon from
   this sandbox. A scoped eval of the touched host fully type-checks your change
   (every module that host imports is evaluated) without that cost:
   ```
   nix eval ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
   ```
   Run it once per host whose files you edited (e.g. `hermes`, `dns`). A printed
   `/nix/store/….drv` path means the config evaluates cleanly; an error means fix
   it and re-run. First eval after a fresh branch can take a few minutes while the
   flake inputs warm up — that is normal, not a failure. `nix` runs builds via the
   host nix-daemon; `nix develop` provides `just`, `alejandra`, `tofu`, etc. from
   the repo's dev shell. (The user runs the full `just nixos-check` on the host
   before merging/deploying — that broad gate is theirs, not yours.)

4. **Commit** with a clear conventional-commit message (imperative, lowercase, no
   trailing period). Commit **through the dev shell** so the repo's lefthook
   pre-commit hooks (`alejandra`, `keep-sorted`) are on PATH and actually run — a
   bare `git commit` fails those hooks in this sandbox because the tools aren't on
   the container PATH:
   ```
   git -C "$HOMELAB_REPO_PATH" add -A
   cd "$HOMELAB_REPO_PATH" && nix develop -c git commit -m "<type>(<scope>): <summary>"
   ```
   Examples: `feat(hermes): add foobar service`, `fix(dns): correct PTR record`,
   `chore(flake): bump inputs`. Keep commits focused and small. Do NOT pass
   `--no-verify` to skip the hooks — run them via `nix develop` as shown.

5. **Stop.** Tell the user the branch name and a short summary of the change.
   Do not push — the host service does it. They will see the branch on Forgejo.

## Notes & pitfalls

- New `.nix` files must be `git add`ed before `nix eval` / `nix flake check` sees
  them (the flake only evaluates tracked files). Stage new files first
  (`git -C "$HOMELAB_REPO_PATH" add <file>`) if you validate before committing.
- If a command says `nix: command not found`: your sandbox already has nix on
  PATH for normal **terminal** calls (the host puts `${pkgs.nix}/bin` on PATH via
  `docker_env.PATH` and re-adds it for login shells via `/etc/profile.d/hermes-nix.sh`).
  This error usually means you are in a context that reset PATH (e.g. a subshell
  inside `execute_code`). Recover by running the command from the terminal tool as
  `cd "$HOMELAB_REPO_PATH" && nix ...`. If it still fails, put nix on PATH for that
  one command without guessing store paths:
  ```
  export PATH="$(dirname "$(readlink -f /run/current-system/sw/bin/nix 2>/dev/null || command -v nix)"):$PATH"
  ```
  and report it to the user — a persistently missing `nix` means the host config
  needs a redeploy, which only the user can do.
- Adding a whole new host is a multi-file change — follow the "Adding New Hosts
  Checklist" in the repo's `AGENTS.md` (flake registration, DNS, monitoring, …).
- Do not edit secrets (`.age` files) or attempt to decrypt them; you don't have
  the keys. If a change needs a new secret, describe it for the user to create.
