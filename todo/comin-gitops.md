# Comin (pull-based GitOps) alongside Colmena

Add [comin](https://github.com/nlewo/comin) so every NixOS host polls this repo's
`main` branch on Forgejo and deploys itself, while keeping colmena available for
manual pushes.

**Status — plan for review (2026-08-17), not started.**

## Corrections to the initial assumptions

Two things in the original request don't match how this repo/comin actually work —
flagging them up front so the plan below makes sense:

1. **`iac/main.tf` does not map VMs to `hosts/` subfolders, and comin doesn't need
   it to.** Comin runs *on* each host, clones the repo, and evaluates
   `nixosConfigurations.<name>` from the flake. The mapping from flake attribute to
   `hosts/<hostname>/configuration.nix` already lives in `flake.nix` (`mkHost`).
   The only conceivable IaC touch is a **memory bump for the tiny VMs** (see
   "Build resources" below) — no per-VM subfolder wiring.
2. **Flake attribute names ≠ `networking.hostName`.** Every host sets
   `networking.hostName = "homelab-<name>"` (e.g. `homelab-database`), but the
   flake attributes are the bare names (`database`). Comin derives the
   configuration from the hostname by default, so out of the box it would look for
   `nixosConfigurations.homelab-database` and fail. Fix: set
   `services.comin.hostname = "<flake-attr>"` explicitly per host (the option
   exists for exactly this).

## Verified facts (2026-08-17)

| Fact | Value |
| --- | --- |
| Repo URL (canonical) | `https://forgejo.homelab.local/amadeus/pve-nixos-homelab.git` |
| Anonymous clone | **Works** (`git ls-remote` with no creds succeeded) → no auth secret needed for comin |
| TLS | `forgejo.homelab.local` carries a step-ca cert; all hosts import `modules/step-ca-trust.nix` → clones succeed |
| `main` branch protection | Already on (hermes-bot setup) → comin only deploys reviewed merges. Good fit. |
| Hostname mismatch | `homelab-<name>` vs flake attr `<name>` on all hosts → `services.comin.hostname` override required |
| home-manager parity gap | `colmenaHive.defaults` adds `homeManagerNixvim` to every node; `mkHost` **omits** it (only `development`/`jellyfin` bake it in). Comin builds `nixosConfigurations`, colmena builds the hive → the two would fight (see below) |
| Comin key options | `services.comin.hostname`, `remotes.*.url`, `remotes.*.branches.main.operation` (default `switch`), `branches.testing.name` (default `testing-<hostname>`, operation `test`), `poller.period` (default 60s), `exporter.port` (default 4243), `retention.*` (keeps 3 boot entries) |

## The one real design problem: colmena/comin drift

Colmena and comin build **different module sets** for the same host:

- `colmena apply` → hive node = `hosts/<name>/configuration.nix` + disko + agenix
  **+ `homeManagerNixvim` (via hive defaults)**.
- comin → `nixosConfigurations.<name>` via `mkHost` = same **minus
  home-manager/nixvim** (except `development`, `jellyfin`, and the explicit
  `mcp`/`hermes` entries).

With comin enabled, every poll would switch the host to the non-home-manager
closure; the next colmena apply would put nixvim back. Silent flip-flop, and
exactly the class of drift AGENTS.md already warns about for `nixos-check` vs the
hive. **This must be fixed before comin is enabled anywhere.**

Chosen approach (proposed): extend `mkHost` to include `homeManagerNixvim` and the
comin module, so `nixosConfigurations` and the hive converge. Notes:

- `minimal` and `iso` use `mkHost`/`nixosSystem` too — they must **not** get
  home-manager or comin (installer/bootstrap images). Give `mkHost` a flag or keep
  `minimal`/`iso` on their own explicit path.
- `development`/`jellyfin` are already explicit and include `homeManagerNixvim` —
  add the comin module there too.
- `mcp` and `hermes` are explicit (special flake inputs) — add comin there too,
  no home-manager change.
- Alternative (rejected): a separate per-host module list only for comin hosts.
  It re-introduces the two-sources-of-truth problem in a new place.

## Coexistence rules with colmena (workflow change)

- Comin polls every 60s and runs `switch-to-configuration switch` on any new
  `main` commit. **A colmena apply of uncommitted/local state is reverted by
  comin within a minute.** After rollout, "commit → merge to main" is the deploy;
  colmena stays for emergencies, bootstrapping, and one-off `test`s.
- For risky changes, comin's testing branches are the intended path: push
  `testing-<flake-attr>` (e.g. `testing-database`), the matching host deploys it
  with operation `test` (not persisted to boot), then merge to `main`.
- Comin never rolls back on fetch/build failure — it retries and stays on the
  last good generation. A broken commit breaks *that host's next deploy*, not the
  running system. Rollback remains the boot menu (comin keeps 3 boot entries).
- Circular-dependency check: hosts resolve `forgejo.homelab.local` via unbound on
  the `dns` host. If `dns` dies, polls fail safe (retry, no downgrade). The
  GitHub mirror is deliberately **not** added as a second comin remote: it lags
  `main`, and comin picks the newest `main` commit across remotes — a stale
  mirror invites confusion, not redundancy.

## Build resources (the only possible IaC change)

Comin **builds on the host itself** — there is no remote-build option. Most
closures substitute from cache.nixos.org/attic, so the cost is mostly **nix
evaluation RAM**, not compilation. Rough budget: 1–2 GB for a single-host eval of
this flake. Hosts at risk:

| Host | dedicated RAM | Concern |
| --- | --- | --- |
| `dns` | 768 MB | Likely OOM during eval |
| `ca` | 768 MB | Likely OOM during eval |
| `unifi` | 2560 MB | Probably fine |
| everything else | ≥1536 MB | Probably fine |

Plan: measure on the pilot host, then bump `dns`/`ca` to 1536 MB in
`iac/main.tf` if needed (that's the whole IaC diff). Do **not** preemptively
resize before measuring.

## Rollout plan

### Phase 0 — Decisions (review this file)

- [ ] **0.1** Confirm the mkHost/home-manager unification approach above.
- [ ] **0.2** Confirm host scope: all colmenaHive nodes (database, otel, dns,
      unifi, containers, mcp, hermes, ca, fleet, harbor, cache, forgejo,
      woodpecker, development, jellyfin). Excluded: `minimal`, `iso`, `rpi*`,
      commented-out k3s/zeroclaw. (`zeroclaw` is in nixosConfigurations but not
      the hive — include or skip, your call.)
- [ ] **0.3** Confirm `main`-only to start; testing branches documented but
      optional per change.

### Phase 1 — Flake changes (single PR, no host behavior change yet)

- [x] **1.1** Add the comin input to `flake.nix`
      (`github:nlewo/comin`, `inputs.nixpkgs.follows = "nixpkgs"`).
- [x] **1.2** Create `modules/comin.nix`: takes the flake attribute name,
      imports `comin.nixosModules.comin`, sets `services.comin.hostname` and
      the Forgejo remote. Exporter off for now (Phase 4).
- [x] **1.3** Rework `mkHost`: now includes `homeManagerNixvim` + comin via the
      `cominFor` helper. `minimal` and `iso` are explicit comin-free/hm-free
      `nixosSystem` entries.
- [x] **1.4** Add comin (+ `homeManagerNixvim` + `allowUnfree`) to the explicit
      entries (`development`, `jellyfin`, `mcp`, `hermes`) and `(cominFor
      "<name>")` to all 15 colmenaHive nodes.
- [~] **1.5** Verify: `just fmt` ✅. Scoped per-host evals ✅ (all 19
      nixosConfigurations evaluate; `services.comin.hostname` correct on all 18
      comin hosts, absent on `minimal`). `just colmena-build-host otel` ✅
      (hive + home-manager + comin build together; `comin.service` in the
      closure). ⚠️ **`just nixos-check` (full `nix flake check`) was OOM-killed
      (signal 9) on this 7 GB workstation** — adding home-manager+nixvim to
      every mkHost host made the whole-flake eval heavier than RAM. Per-host
      evals all pass, so this is a machine limit, not a config error — but the
      pre-merge gate now needs a bigger-RAM machine or a scoped-check recipe.
- [ ] **1.6** Confirm no-expected-diff sanity: for one host, compare
      `nixosConfigurations.<host>` toplevel before/after — should differ only by
      the comin service + home-manager addition. (Skipped: the hm+comin
      addition *is* the intended diff; the otel hive build is the evidence.)

### Phase 2 — Pilot (one host)

- [ ] **2.1** Pick a low-blast-radius host: **`otel`** (monitoring; a bad deploy
      breaks dashboards, not DNS/CA/git).
- [ ] **2.2** Bootstrap via colmena (chicken-and-egg: the comin service itself is
      delivered by the last colmena apply): `just colmena-apply-host otel`.
- [ ] **2.3** Verify on the host: `systemctl status comin`,
      `journalctl -u comin -f` shows a successful poll + "already up to date".
- [ ] **2.4** End-to-end test: trivial commit to `main` (e.g. a comment), watch
      comin eval/build/switch within ~60s. Measure eval RAM (`/proc` peak or
      systemd `MemoryMax=` accounting) to size the `dns`/`ca` question.
- [ ] **2.5** Revert-test: push a deliberately broken config to
      `testing-otel`, confirm `test`-operation behavior and that `main` state is
      unaffected.

### Phase 3 — Fleet rollout (batches, each = one colmena apply to bootstrap comin)

- [ ] **3.1** Batch 1 (leaf services): cache, harbor, fleet, containers, mcp.
- [ ] **3.2** Batch 2 (stateful/user-facing): database, jellyfin, woodpecker,
      forgejo.
- [ ] **3.3** Batch 3 (agents/dev): development, hermes.
- [ ] **3.4** Batch 4 (infrastructure, last and one at a time): unifi, **ca**,
      **dns** — with the memory bump from Phase 2 measurements applied first if
      needed. `dns` last: if its deploy breaks unbound, every other host's comin
      polls start failing (safe, but noisy).
- [ ] **3.5** After each batch: `systemctl status comin` per host; one real
      commit to `main` and confirm all batch hosts converge.

### Phase 4 — Observability & docs

- [ ] **4.1** Enable `services.comin.exporter` (port 4243) and add a
      `comin` scrape job per host in `hosts/otel/configuration.nix` (follow the
      AGENTS.md pattern: DNS name + explicit `labels.instance`).
- [ ] **4.2** Update `AGENTS.md`: new deploy workflow (merge-to-main deploys;
      colmena for bootstrap/emergency), comin in "Key Technologies", and extend
      the "Adding New Hosts Checklist" (comin module + `services.comin.hostname`).
- [ ] **4.3** Optional justfile helper: `just comin-status <host>` wrapping
      `ssh <host> systemctl status comin`.
- [ ] **4.4** Optional: a Woodpecker CI gate that builds changed hosts on PRs,
      since `main` now auto-deploys (`.woodpecker/nix.yml` already evaluates;
      check whether it's strong enough to be the only pre-merge gate).

## Open questions — RESOLVED (2026-08-17)

1. **`hermes` feature-branch flow vs comin.** ✅ **Merge-is-deploy AND colmena
   both stay.** Merging a PR deploys via comin; colmena remains for
   bootstrapping, emergencies, and one-off pushes.
2. **`deployment.operation` for `main`.** ✅ **`switch` everywhere** (comin
   default); drop to `boot` on a specific host only if it proves necessary.
3. **GitHub mirror as comin remote.** ✅ **No.** Single remote: Forgejo.
