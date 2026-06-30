# Config improvements (all hosts)

Audit of structural / maintainability wins across the flake + Colmena setup.
None are live outages — these are reproducibility, DRY, and drift-prevention.
Ordered by impact.

## Done
- [x] **Fix `system` deprecation warning** — replaced the deprecated top-level
  `system` arg to `nixpkgs.lib.nixosSystem` with `{nixpkgs.hostPlatform = …;}`
  modules in `mkHost` + the inline `mcp`/`hermes`/`rpi4`/`rpi5` defs (`flake.nix`).

## High impact
- [ ] **Fold shared modules into `mkHost`** — every ~18 hosts copy
  `common.nix` + `tailscale.nix` + `step-ca-trust.nix` imports. Move into
  `mkHost` (and the shared module list), drop the per-host lines. The
  `nixpkgs.hostPlatform` line added above belongs here too.
  - Files: `flake.nix` (`mkHost`), every `hosts/*/configuration.nix` import block.
- [ ] **Single source of truth for host module lists** — `nixosConfigurations`
  and `colmenaHive` both spell out each host's `imports` (two edits per host,
  easy to drift). Generate `colmenaHive` entries from a shared `hosts` table
  (name → {tags, extraModules}); fold `mcp`→hamcp, `hermes`→hermes-agent as
  per-entry `extraModules`.
- [ ] **Move `system.stateVersion` out of `common.nix`** — it's shared `"25.05"`
  for all hosts (`modules/common.nix:163`) but is a per-machine value that must
  never be bumped globally. Pin it per-host in each `hosts/*/configuration.nix`.
- [ ] **Pin `hermes-agent` to a commit, not a PR ref** — `flake.nix:25` uses
  `github:NousResearch/hermes-agent/pull/49431/head`; PR refs get
  rebased/closed → not reproducible. Pin `?rev=…` or a fork branch you control.

## Medium impact
- [ ] **De-duplicate host IPs** — `hostAddrs` (`flake.nix`), `iac/main.tf`,
  `hosts/dns/configuration.nix` (A/PTR), and the Prometheus targets in
  `hosts/otel/configuration.nix` each hardcode `192.168.2.x`. Promote one shared
  table the DNS + otel hosts consume.
- [ ] **Generate Prometheus node jobs** — `hosts/otel/configuration.nix:245-488`
  lists 22 `*-node` jobs by hand (new hosts get forgotten). Map over the host
  table; keep only bespoke jobs (vllm, hofvarpnir, axon-gateway) literal.
- [ ] **Add CI gate** — no `.github/workflows` / Forgejo Actions despite running
  Forgejo + Buildbot. Add a job running `nix flake check` + `alejandra --check`
  on PRs to `main` (lefthook only guards local commits).
- [ ] **Fix AGENTS.md drift** — §1 references `just nixos-build-all` /
  `nixos-build-otel` that don't exist in the `justfile`. Add them or fix the doc.
  Consider moving deep incident runbooks to `docs/`.

## Hygiene
- [ ] **Drop dead commented-out config** in `flake.nix` (k3s-server-1,
  k3s-agent-1, jellyfin, rpi4-1 in both `nixosConfigurations` + `colmenaHive`,
  and `hostAddrs`) — git history keeps them.
- [ ] **Remove stale alias** `flk = "cd /etc/nixos"` (`modules/common.nix:56`) —
  repo isn't deployed there.
- [ ] **Add a firewall baseline in `common.nix`** — all 18 hosts roll their own
  `networking.firewall` with no shared default-deny posture.
- [ ] **(Info) agenix blast radius** — `tailscale-auth-key.age` and
  `fleet-enroll-secret.age` are encrypted to the full `users` list (every host
  key). Reasonable for shared enrollment keys, but a conscious confirm.

## Verification (per change, before deploy)
- `just fmt` then `nix flake check`.
- Refactors (fold-modules, stateVersion) must be **no-ops** on the realized
  system — `just colmena-build` + `just drift` should show no toplevel change for
  already-correct hosts.
- For generated DNS / Prometheus: build `dns` + `otel`, diff rendered config vs
  current to prove equality before relying on generation.
- Deploy one host first (`just colmena-apply-host <host>`) and check
  `systemctl status` + the otel dashboard before fleet-wide `colmena-apply`.

## Suggested order
#1 + stateVersion (low-risk dedup) → hermes-agent pin → host-table work
(#2 + IP dedup + Prometheus gen, they reinforce one table) → CI.
