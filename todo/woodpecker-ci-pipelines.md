# Woodpecker CI pipelines (`.woodpecker/`)

Three pipelines run on every push / PR to `amadeus/pve-nixos-homelab` on
Forgejo, served by the `woodpecker` host (`https://ci.homelab.local`):

| Pipeline       | File                      | What it does                                                      |
| ---            | ---                       | ---                                                               |
| `static.yml`   | format + commit-message   | `alejandra -c .`, `keep-sorted --mode lint`, `cog check` on the pushed range |
| `iac.yml`      | OpenTofu / IaC            | `tofu fmt -check`, `tofu init -backend=false` + `tofu validate`, kics scan |
| `nix.yml`      | NixOS config check        | scoped per-host `nix build --dry-run` of changed hosts, **pulling from the attic cache** |

`static.yml` and `iac.yml` run in a self-built image
(`harbor.homelab.local/ci/pve-nixos-homelab:latest`, defined in `flake.nix`
as `packages.ci-image`). `nix.yml` runs in `nixos/nix:2.35.2` from Docker Hub.

## Design decisions (read before "simplifying")

- **Scoped nix eval, never `nix flake check`.** The full check evaluates all
  ~16 hosts and gets OOM-killed (exit 137) on the host nix-daemon — the same
  reason the hermes agent evals one host at a time (AGENTS.md §7). CI diffs
  the pushed range and evaluates only the hosts under `hosts/<dir>/` it
  touched (`mcp_vm` maps to the `mcp` attr; `rpi*` is skipped — those are
  aarch64). No hosts changed → falls back to `dns woodpecker`.
- **`colmenaHive` is NOT checked.** `nixosConfigurations` (via `mkHost`)
  omits the home-manager/nixvim layer, and `colmenaHive` isn't a standard
  flake output so `nix flake check` skips it too. The only gate that builds
  that layer is `just colmena-build` — a human, pre-deploy action. CI does
  not run it, and CI must NOT auto-deploy (deploys stay human-gated).
- **`cog check` is scoped to the pushed commits**, not full history: older
  commits predate conventional-commit enforcement (`cog check` on all of
  history fails 23 commits). `--ignore-merge-commits` lets merge-commit PR
  merges through. The lefthook `commit-msg` hook stays the primary gate.
- **kics ships no queries in nixpkgs and will not download them.** The CI
  image vendors the query pack from the kics release tag
  (`Checkmarx/kics` @ the commit for `v2.1.19`) into `/opt/kics-queries`,
  and the pipeline passes `-q /opt/kics-queries`.
- **kics `--exclude-paths` is a REPEATED flag.** A comma-joined value is
  treated as one literal path and makes kics dump usage and exit.
- **Attic cache in the nix step.** `NIX_CONFIG` sets `substituters` to
  `https://cache.homelab.local/homelab` (+ `cache.nixos.org`) and
  `NIX_SSL_CERT_FILE`/`GIT_SSL_CAINFO` point at
  `/etc/ssl/certs/ca-certificates.crt` — the path the woodpecker agent's
  `WOODPECKER_BACKEND_DOCKER_VOLUMES` bind-mounts the host step-ca bundle
  over. Verified: `nix store info --store https://cache.homelab.local/homelab`
  succeeds with that TLS config.

## One-time setup (outside this repo)

1. **Harbor project + image.** Create a public `ci` project in Harbor
   (`harbor.homelab.local`), `podman login harbor.homelab.local`, then
   `just ci-image-push`. Until the image exists, `static.yml`/`iac.yml`
   fail with an image-pull error — expected during bring-up.
2. **Forgejo deploy key.** Create the secret `forgejo_ci_ssh_key` in the
   Woodpecker repo settings (Settings → Secrets), value = an ed25519 private
   key. Add its public half to a Forgejo deploy key (or `ci` user) with
   **read** access to `amadeus/homelab-mcp-servers`. Only used when the
   evaluated host imports the `homelab-mcp` git+ssh input (`mcp`, `hermes`).
3. **Repo webhook.** The `ci.homelab.local` webhook must be registered on
   `amadeus/pve-nixos-homelab` (Forgejo repo → Settings → Webhooks). The
   `forgejo.homelab.local`/`ci.homelab.local` ALLOWED_HOST_LIST entry on the
   forgejo host already exists (AGENTS.md §6) — do not remove it.

## Rebuilding the CI image

Tool bumps happen in `flake.nix` → `packages.ci-image`, then:

```bash
just ci-image-push
```

Note the kics query pin: it lives at the commit for the kics *version*
nixpkgs currently ships. Bumping `pkgs.kics` means bumping the
`kicsQueries` `rev` too. If the `kicsQueries` hash ever mismatches, it is
the **unpacked-tree** hash (`nix-prefetch-git --rev <sha>`), not the raw
tarball hash (`nix-prefetch-url`) — GitHub regenerates tarballs with fresh
gzip metadata, so the raw file hash drifts on every download.

## Known gaps

- Pipelines use a full clone (`partial: false`) so `CI_COMMIT_BEFORE` is
  reachable for the diff/cog range. The repo is small; fine.
- The `nixos/nix:2.35.2` pull is anonymous from Docker Hub. If Docker Hub
  ever rate-limits the woodpecker host, mirror it into Harbor and change the
  image reference here.
- `nix.yml` does not exercise the git+ssh `homelab-mcp` input unless `mcp`
  or `hermes` is actually changed. If the CI key is missing and one of those
  hosts is edited, the eval fails with an SSH error — add the secret.
