# Hermes Rebuild Plan — Wipe, XFS on ssd_pool, Multi-Profile, Agent Account

Date: 2026-09-23 (rev. 2026-09-23: cron, agent account, coding harness)
Status: plan only, nothing implemented.
Companion: `docs/hermes-agent-findings-2026-09-23.md` (upstream state, capability gaps).

## 1. What Changes

**Goal.** Destroy VM 4334 and rebuild hermes from scratch: XFS root on `ssd_pool`,
current upstream `hermes-agent`, several isolated agent profiles with scheduled jobs,
reachable only as an interactive agent over ssh/mosh plus moshi-hook push. The agent
gets its own non-sudo account with a Forgejo collaborator key and drives `opencode` /
`claude` as its coding tools — the same shape as `hosts/development`. Nothing from the
old state dir is migrated.

**In:**

- New blank disk on `ssd_pool`, `modules/disko-xfs.nix`, installer-ISO provisioning.
- `hermes-agent` unpinned to `v2026.9.21`.
- Profiles `default`, `coding`, `research`, `kb` — separate `config.yaml`, `.env`,
  `SOUL.md`, memory, sessions, checkpoints and **cron jobs** per profile (§7, §8).
- One unprivileged unix user `hermes` owning several profile homes under
  `~/.hermes/profiles/` (§5), one multiplexing gateway (§7.4), and **one dashboard that
  sees every profile** at `hermes-dashboard.homelab.internal`, authenticated with Pocket
  ID OIDC (§9.1).
- A Forgejo account of the host's own, `hermes`, with its own SSH key, pushing `main`
  directly (§5.2, §5.3), with `repo-sync` keeping its `~/code` checkouts current.
- Per-profile checkpoints/rollback, enabled for `coding` (§7.3).
- The shared coding harness: Claude Code + opencode, repo skills and commands, MCP
  wiring — for the `coding` profile only (§6).
- moshi-hook (per profile) + mosh/ssh over Tailscale as the *only* human interfaces.

**Out (deleted, not migrated):**

- The api_server, its `hermes.homelab.local` / Tailscale Caddy vhosts, and the
  `hermes-api-server-key` secret. Open WebUI stops being a client (§12). Caddy itself
  stays, for the dashboard vhost only (§9.1).
- The Obsidian vault: `hermes-vault-git-setup`, `hermes-vault-bootstrap`,
  `OBSIDIAN_VAULT_PATH`, the `obsidian-vault-notes` skill and the SOUL.md sections
  that drive it.
- The bespoke homelab-repo plumbing — `hermes-repo-sync` + its timer, the
  `HOMELAB_REPO_PATH` env var, the `homelab-config-repo` skill, and the hand-written
  branch/commit/push protocol in SOUL.md. Repo access itself **returns** in a
  different shape: `modules/repo-sync.nix` + the agent account (§5), with the harness
  doing the actual work (§6).
- The `cron-result-delivery` skill — upstream delivers natively now (§8).
- The `launch-hermes` and `opencode` shell wrappers in `environment.systemPackages`;
  both are replaced by the harness and by logging in as the agent account directly.

## 2. Infrastructure — `iac/main.tf`

Current `hermes_vm` (line ~594): 2 cores, 2048 MB dedicated / 1024 floating, **256 GB
disk on `zfs_pool`** imported from the Debian cloud image, `started = false`,
`on_boot = false`.

Target block:

```hcl
  cpu {
    cores = 4          # was 2 — several profiles, an agent loop, plus nested
                       # opencode/claude runs and nix evals
    type  = "host"
  }

  memory {
    dedicated = 8192   # pinned: floating == dedicated, no ballooning
    floating  = 8192
  }

  # ssd_pool + XFS, same reasoning as dns_vm/ca_vm. BLANK disk, no file_id:
  # importing a cloud image onto this zfspool fails with "no zvol device link
  # ... after 10 sec". The installer comes from the CD-ROM below.
  disk {
    datastore_id = "ssd_pool"
    interface    = "scsi0"
    size         = 64
    discard      = "on"
    file_format  = "raw"
  }

  cdrom {
    file_id   = "local:iso/nixos-homelab-<rev>-x86_64-linux.iso"
    interface = "ide0"
  }

  boot_order = ["scsi0", "ide0"]

  started = true
  on_boot = true
```

Notes:

- **Keep `vm_id = 4334`** and the resource name so DNS (192.168.2.155) and the
  Proxmox inventory output at line ~1562 stay valid.
- Dropping `file_id` and changing `datastore_id` on the disk is a **replacement**, not
  the in-place move the woodpecker block documents (that one kept its `file_id`).
  That is the intent here — confirm with `tofu plan` that it shows the disk replaced
  and the VM otherwise stable before applying.
- **8192 / 64 GB is sized for the harness, not the agent.** A bare Hermes would be fine
  at 6144/48. What pushes it up is §6: nested `opencode`/`claude` runs, `nix develop`
  realising devShells, node_modules trees, and several repo clones under `~/code`.
  `development` is the precedent for how much that actually costs. This node is already
  oversubscribed (`todo/pve-gigabyte-memory-oversubscription.md`) — if 8 GB cannot be
  spared, take 6144 and expect devShell realisation to be the thing that hurts.
- Add zram on the NixOS side, as `development` does, so the first response to a
  memory spike is compression rather than IO on the pool:

  ```nix
  zramSwap = { enable = true; algorithm = "zstd"; memoryPercent = 25; };
  ```
- `file_id` on the cdrom must match an ISO actually uploaded to `local` — `just
  iso-build` then re-upload; the string carries the nixpkgs rev and changes every time.

## 3. Filesystem — `modules/disko-xfs.nix`

`hosts/hermes/configuration.nix:268` imports `../../modules/disko-config.nix` (btrfs
subvolumes + swapfile). Swap the import to `../../modules/disko-xfs.nix`.

That module is the repo's documented default for new VMs and is the right answer here:
the guest disk is a zvol on a ZFS pool, so btrfs stacks a second CoW layer and a
second zstd compression pass on top of one that is already doing both. XFS also gives
a real 4 G swap partition (rather than a swapfile on a CoW subvolume), pins the disk by
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0` instead of `/dev/sda`, and
enables weekly `services.fstrim` — which is why `discard = "on"` in §2 matters.

No host-specific override is needed: hermes has one disk at scsi0.

## 4. Upstream Bump

Lift the pin in `flake.nix` to the current release and drop the pin comment:

```nix
hermes-agent = {
  url = "github:NousResearch/hermes-agent/v2026.9.21";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

The `registration_lifecycle` crash that caused the pin is fixed upstream and now has a
build-time regression check. Full detail, plus the three pre-bump checks (plugin import
decomposition, `hermesHomeFiles` vs `documents` for SOUL.md, gateway singleton lock),
is in the findings doc §2–§3. **Do those checks as part of this rebuild** — a wipe is
the cheapest moment to discover that a plugin no longer loads.

Validate with a scoped eval only:

```bash
nix eval '.#nixosConfigurations.hermes.config.system.build.toplevel.drvPath'
```

Not `nix flake check` (evaluates ~16 hosts, OOMs), and leave the full `colmena build`
to a session that can absorb the compile.

## 5. One `hermes` User, Many Profile Homes

**Decided: a single unix user, `hermes`, owning several profile homes.** Each profile
still gets its own home *directory* — `~/.hermes/profiles/<name>/`, with its own
`config.yaml`, `.env`, `SOUL.md`, `memories/`, `sessions/`, `skills/`, cron jobs,
checkpoints and `state.db` — but they share one uid. That is upstream's paved path, and
it is what makes the two features that matter here work: **one dashboard that sees every
profile** (§9.1) and **one multiplexing gateway** (§7.4).

The trade, stated plainly: isolation between profiles is now Hermes' bookkeeping, not
the kernel. `coding` and `research` run as the same user and can read each other's
`.env`. What still holds is the boundary that matters most — `hermes` is not `amadeus`,
has no sudo, and cannot read `~amadeus/.ssh` (the colmena deploy key) or run
`nixos-rebuild`. Plus the unit sandbox: `ProtectSystem=strict`, the `IPAddress*`
allow-list, `ReadOnlyPaths` on every profile's config and SOUL.

**No `homelab.agent` account.** `modules/agent-user.nix` exists to split a workstation
between a human and one agent; here the whole machine is the agent and the account is
simply `hermes`. Its *options* are still needed, though — see §6.

### 5.1 The account

The upstream module creates a `hermes` user of its own (`createUser = true`,
`user = "hermes"`, home = `stateDir` = `/var/lib/hermes`) — a **system** account. We
want a normal one with a real home, because the same account logs in over mosh, holds
the coding harness (`~/.claude`, `~/.config/opencode`) and keeps repo checkouts under
`~/code`. So define the account ourselves and point the module at it:

```nix
users.users.hermes = {
  isNormalUser = true;
  home = "/home/hermes";
  shell = pkgs.zsh;
  linger = true;                                    # user services start at boot
  openssh.authorizedKeys.keys = config.homelab.users.amadeus.sshKeys;
};

# No sudo, explicitly — an absent grant can be widened later; a deny cannot.
security.sudo.extraRules = [
  { users = ["hermes"]; commands = [{ command = "!ALL"; }]; }
];

services.hermes-agent = {
  user       = "hermes";
  createUser = false;        # we own the account
  stateDir   = "/home/hermes";   # → /home/hermes/.hermes/
};
```

Profiles then live at `/home/hermes/.hermes/profiles/<name>/`. The module's
`commonServiceConfig` sets `ProtectHome = false`, so `/home/hermes` is reachable from
inside the unit, and `ReadWritePaths = [stateDir, workingDirectory]` covers it.

**Verify during the bump** that `user`, `createUser = false` and a non-`/var/lib`
`stateDir` behave as documented on `v2026.9.21` — the option list was read from
`nix/nixosModules.nix` on main, not exercised.

### 5.2 The Forgejo identity

**One Forgejo account for this host, named `hermes`, with its own SSH key.** Forgejo
resolves the account from the key fingerprint, so one public key belongs to exactly one
account, and a per-host key keeps revocation and attribution per-host.

| Thing | Value |
| --- | --- |
| Forgejo account | `hermes` / `hermes@homelab.local`, unrestricted, **not** admin |
| SSH key | fresh ed25519, registered on that account as `homelab-hermes` |
| Private key | agenix `secrets/hermes-forgejo-ssh.age`, `0400` to the `hermes` user |
| Commit identity | `user.name = hermes`, `user.email = hermes@homelab.local` |
| API token (optional) | `secrets/hermes-forgejo-token.age`, scopes `write:repository,write:user` |

`todo/forgejo-bot-account-development.md` is the working recipe (it is how
`developmentbot` was created). Two details:

- **`hermes-forgejo-ssh.age` is re-minted, not reused.** It holds the *`hermes-bot`*
  account's key today — the account that served the Obsidian vault and the
  feature-branch flow, both dropped here. Generate a new keypair, `agenix -e` the
  private half into that filename, and retire `hermes-bot` (rename it to `hermes` to
  keep its past commits attributed, or delete it once nothing references it).
- **Every profile can use that key**, since they share a uid. Only `coding` is
  *instructed* to, but that is a convention now, not a boundary. If that ever matters,
  it is the argument for going back to one unix user per profile.

`agent-user.nix` used to write the ssh `Match` block; write it in the host config
instead:

```nix
programs.ssh.extraConfig = ''
  Match user hermes host forgejo.homelab.local,forgejo.homelab.internal
    Port 2222
    User forgejo
    IdentityFile ${config.age.secrets.hermes-forgejo-ssh.path}
    IdentitiesOnly yes
    IdentityAgent none
    StrictHostKeyChecking accept-new
'';
```

### 5.3 Repo checkouts and pushing `main`

```nix
homelab.repoSync.hermes = {
  sshKey = config.age.secrets.hermes-forgejo-ssh.path;
  push   = true;
};
```

`modules/repo-sync.nix` then walks every checkout under `~/code` on a timer: fetch →
`merge --ff-only` (refuses on divergence) → plain `push` (no `--force`, ever). It never
commits or rebases, and exits 0 on every skippable state, so a dirty tree is not a
failure. That is how commits reach Forgejo without a human step, and it is what the
`coding` profile operates on: clones under `/home/hermes/code`.

**It pushes `main` — decided.** Same model as `development`: commit and push directly,
no PR round-trip, so the `coding` profile's SOUL.md carries no feature-branch protocol.

This needs a Forgejo-side change, and it is not the one `development` needed.
`development` was never blocked because `agent-forgejo-ssh` holds *amadeus's own
collaborator key* — that host pushes as you. The `hermes` account is a separate
identity, and `main` on `amadeus/pve-nixos-homelab` is protected with no push whitelist
precisely so the old `hermes-bot` could not land changes (AGENTS.md §7). So: **add
`hermes` to the push whitelist on the protected `main` branch**, per repo it should work
in. Web UI, one setting; nothing in this repo.

Two consequences worth stating before doing it:

- **Nothing auto-deploys from `main` any more.** Comin was removed on 2026-09-08
  (`todo/comin-removal-cleanup.md`), so a push to `main` reaches Forgejo and stops
  there — `repo-sync` fast-forwards the human clone, and a person still runs
  `just self-deploy` / `colmena`. Had comin still been running, an agent push to `main`
  would have been a fleet-wide unreviewed deploy; it is not.
- **AGENTS.md §7 becomes wrong.** It documents the feature-branch workflow, the
  `~/workspace/pve-nixos-homelab` checkout, the `homelab-config-repo` skill and "main is
  branch-protected, so the bot can never land changes directly". All four are superseded
  here; rewriting it is part of the work (§12).

## 6. Coding Harness — opencode and Claude Code

The `coding` profile should not be doing code edits with Hermes' own `file`/`patch`
tools when a purpose-built harness already exists in this repo. Import the same set
`development` does:

```nix
imports = [
  ../../modules/agent-user.nix       # for its OPTIONS only; enable stays false
  ../../modules/coding-harness.nix
  ../../modules/claude-permissions.nix
  ../../modules/claude-settings-verify.nix
  ../../modules/repo-sync.nix
  ../../modules/moshi-hook-user.nix
  ../../modules/forgejo-cli.nix      # optional: `fj` for repo creation over REST
  # ../../modules/herdr.nix          # optional: terminal workspace for mosh sessions
];
```

Those modules read `config.homelab.agent.{user,home}`. The options are declared
unconditionally in `modules/agent-user.nix` — only its `config` block is gated behind
`enable` — so:

```nix
homelab.agent.enable = false;      # no separate agent account on this host
homelab.agent.user   = "hermes";   # who the harness modules configure
homelab.agent.home   = "/home/hermes";
```

That is a small abuse of an option named `agent`; the honest alternative is to give
those modules their own `homelab.codingHarness.{user,home}` options defaulting to
`homelab.agent.*` for `development`. Either way there is one harness in one home, shared
by every profile — only `coding`'s SOUL.md tells it to use them.

`modules/coding-harness.nix` renders, for that account: Claude Code's
`~/.claude/settings.json` (MCP servers as `type = "http"` with `${VAR}` header
expansion), opencode's `~/.config/opencode/` (same servers as `type = "remote"` with
`{env:VAR}`), the repo's skills from `.opencode/skills/` symlinked into
`~/.claude/skills/` (read by *both* tools), and the slash-commands from
`.opencode/command/`. MCP servers come from one list in that module — `axon-gateway` and
`ventara-gateway` — so hermes inherits both by importing it.

### 6.1 What Hermes actually runs

Hermes' `terminal` toolset (backend `local`) executes as the `hermes` user, so the
harness is simply on its PATH. The `coding` profile's SOUL.md directs it to shell out
rather than edit directly, e.g. `opencode run "<task>"` inside
`/home/hermes/code/<repo>`, or `claude -p "<prompt>"`. Consequences worth writing into
the config comments:

- **Guardrails come from the harness, not from Hermes.** Hermes' approval layer sees one
  `opencode` invocation; everything the nested agent then does is governed by
  `modules/claude-permissions-data.nix` and the `opencodePermissions` block — plus the
  unprivileged account, which is the real boundary.
- **Resource caps must be raised.** The current unit sets `MemoryHigh = 3G`,
  `TasksMax = 512`, `LimitNPROC = 512`. One gateway now serves every profile, and a
  nested node/opencode process plus a `nix develop` will exceed that on its own. Raise
  or drop `MemoryHigh` (the existing comment explains why there is deliberately no
  `MemoryMax`) and lift the task caps.
- **`IPAddressAllow` must cover Forgejo** (192.168.2.178 — already listed) for git, and
  the internet stays open for `api.anthropic.com` / opencode-zen since the deny list
  only covers RFC1918 + CGNAT.
- **Cost compounds.** Each nested run bills its own provider. A cron job that calls
  `opencode` is two agents' worth of tokens per tick.

### 6.2 Packaging and credentials

- **`claude-code` is unfree.** The `hermes` entry in `nixosConfigurations` already sets
  `nixpkgs.config.allowUnfree = true` (added for nixvim), so nothing new is needed —
  but unfree packages are not on `cache.nixos.org`, so it builds locally the first time.
- **`crush`** comes from the `nix-ai-tools` flake input, which the `hermes`
  `nixosSystem` entry does **not** pass in `specialArgs` (only `development` does).
  Either add `specialArgs = { inherit nix-ai-tools; }` there, or skip crush.
- **opencode's key**: `modules/coding-harness.nix` expects the generic attribute
  `age.secrets.opencode-zen-key`. Declare it pointing at the existing file:

  ```nix
  age.secrets.opencode-zen-key = {
    file  = ../../secrets/hermes-opencode-zen-key.age;
    owner = "hermes";
    mode  = "0400";
  };
  ```
- **Claude Code's credentials are the open problem.** There is no Anthropic key secret in
  this repo — `development` implies a one-time interactive `claude login`, with the
  result living in `~/.claude`. On a freshly wiped host that is a manual post-install
  step, and an OAuth session is a poor fit for *unattended* cron runs. Treat **opencode
  as the unattended path** (its key is an agenix file) and Claude Code as the interactive
  one, until there is a key-based answer.

## 7. Profiles

### 7.1 The profiles

| Profile | Purpose | Model | Toolsets | Harness |
| --- | --- | --- | --- | --- |
| `default` | host multiplexer + dashboard owner, catch-all | `deepseek-v4-flash` | file, memory, skills, session_search, cronjob | — |
| `coding` | drives opencode/claude in `~/code` | `deepseek-v4-pro` | + terminal, code_execution, delegation | yes |
| `research` | reading, synthesis | `deepseek-v4-pro` | + web (search **and** extract, findings §4.1) | — |
| `kb` | notes / knowledge capture | `deepseek-v4-flash` | file, memory, skills, session_search | — |

`default` exists because the multiplexer and the machine dashboard are both owned by the
default profile (§7.4, §9.1); giving it a cheap model and a thin toolset keeps that
overhead small.

Keep each toolset list minimal: every enabled toolset costs tool-schema tokens on every
LLM call, and `browser` in particular should stay off until it has an engine (findings
§4.2). `coding`'s SOUL.md carries the validation rule — a scoped
`nix eval '.#nixosConfigurations.<host>.…drvPath'` per edited host, never the full
`nix flake check`, which evaluates ~16 hosts and gets OOM-killed.

Access on the CLI: `hermes -p coding chat`, the auto-generated `~/.local/bin/coding`
wrapper (it just sets `HERMES_HOME=…/profiles/coding`), or a sticky
`hermes profile use`. Upstream's hard rule still applies and is now a *discipline*
rather than a permission: **never point two agent processes at the same profile home** —
both write memory, and each loads the other's writes into its system prompt at session
start.

### 7.2 Rendering each profile declaratively

The NixOS module is single-home: `stateDir`, `settings`, `documents`, `environment` and
`environmentFiles` all describe exactly one Hermes home, and there is **no profile
option** upstream. So the secondary profiles need a small local module, e.g.
`modules/hermes-profiles.nix`, driven by one attrset:

```nix
hermes.profiles = {
  coding   = { model = "deepseek-v4-pro";   soul = ./souls/coding.md;   secrets = [...]; };
  research = { model = "deepseek-v4-pro";   soul = ./souls/research.md; secrets = [...]; };
  kb       = { model = "deepseek-v4-flash"; soul = ./souls/kb.md;       secrets = [...]; };
};
```

`lib.mapAttrs'` over that set is the idiomatic NixOS multi-instance pattern
([nixcloud/minimal-example](https://github.com/nixcloud/minimal-example)); here it
generates *files and activation steps*, not units — there is still exactly one systemd
service (§7.4). Per profile:

- Render `config.yaml` and `SOUL.md` into the Nix store (`pkgs.writeText`).
- A root activation script installs them to
  `/home/hermes/.hermes/profiles/<name>/`, `chown hermes:hermes`, and concatenates that
  profile's agenix secret files into that profile's `.env` at mode 0600 — the same
  pattern the upstream module already uses for the root home. (**Check which of
  `documents` / `hermesHomeFiles` upstream now reads the prompt from — findings §3.2.**)
- Bind each rendered `config.yaml` and `SOUL.md` read-only in the unit's
  `ReadOnlyPaths`, as the current config does for the root profile, so the agent cannot
  rewrite its own prompt or model at runtime. With four profiles that is eight paths.

Two things to carry over from the current host:

- **The config.yaml integrity gate.** `hermes-config-check` exists because a malformed
  `config.yaml` makes Hermes fail *open* to built-in defaults (AGENTS.md §6). With N
  profiles there are N files that can be corrupted, so the check must loop over
  `profiles/*/config.yaml`, not just the root one.
- **`secretNonce`.** Writing files at stable paths does not change the unit definition,
  so a deploy does not restart the agent. Keep the nonce and bump it when any profile's
  config, SOUL or secret changes.

### 7.3 Checkpoints and rollback

Hermes can snapshot a project before destructive operations (file writes, patches,
`rm`/`mv`/`sed -i` in the terminal tool) into a shadow git store, and restore it with
`/rollback`. It is **opt-in — `enabled: false` is the default** — and worth turning on
for `coding`, the profile that edits files and shells out to other agents.
([docs](https://hermes-agent.nousresearch.com/docs/user-guide/checkpoints-and-rollback#configuration))

```yaml
checkpoints:
  enabled: false              # master switch (default: false — opt-in)
  max_snapshots: 20           # max checkpoints per project (enforced via ref rewrite + gc)
  max_total_size_mb: 500      # hard cap on total store size; oldest commits dropped
  max_file_size_mb: 10        # skip any single file larger than this

  # Auto-maintenance (on by default): sweep ~/.hermes/checkpoints/ in the
  # background — the CLI on a helper thread right after launch, the gateway
  # on its housekeeping tick — and delete project entries whose last_touch is
  # older than retention_days. Runs at most once per min_interval_hours,
  # tracked via a .last_prune marker. It never blocks the prompt or gateway
  # startup: the `git gc` that reclaims space can take tens of seconds on a
  # large store. This sweep never deletes "orphan" entries (working directory
  # not found) — a missing workdir is ambiguous (deleted project vs. an
  # unmounted external volume / network share / VPN not yet up), so orphan
  # cleanup is only ever done via the explicit `hermes checkpoints prune`
  # command below, with a confirmation prompt.
  auto_prune: true
  retention_days: 7
  min_interval_hours: 24
```

Layout and commands: the store is `~/.hermes/checkpoints/` — `store/` (one shared bare
git repo with per-project refs, content-addressable so objects dedupe across projects),
`legacy-<ts>/` (archived pre-v2 per-project shadow repos), `.last_prune` (the
idempotency marker). `hermes checkpoints` shows size per project;
`hermes checkpoints prune` forces a sweep including orphans; `clear` and `clear-legacy`
delete the store or just the v1 archives. In session: `/rollback`, `/rollback <N>`,
`--all`, `diff <N>`, and per-file restore.

Specifics here:

- **The store is per Hermes home, so it is per profile** — `profiles/coding/checkpoints/`
  and so on, each with its own `max_total_size_mb`. Enable it for `coding` only; leave
  the others at `enabled: false`, since none of them writes code. One 500 MB store is
  what the 64 GB disk in §2 must absorb, not four.
- **`git gc` competes with the agent.** Reclaim runs on a background sweep (CLI launch,
  gateway housekeeping tick) and can take tens of seconds. It is deliberately
  non-blocking, but on a 4-core guest that also runs nested `opencode`, keep
  `min_interval_hours: 24`.
- **Checkpoints are not backups.** They cover the working directory of a project the
  agent touched, in a store that prunes itself on a 7-day retention. Forgejo remains the
  durable copy — the other reason `coding` pushes `main` (§5.3).
- **Container terminal backends skip it.** Not relevant now (`backend = "local"`), but
  worth a comment so a future move to a sandbox backend does not silently lose rollback.

### 7.4 One gateway, multiplexing every profile

`v2026.9.21` enforces a **host-wide singleton lock**: one `hermes gateway run` per
machine, full stop. A second gateway starts in observe-only mode. The mechanism is a
per-role flock plus a published rendezvous record (pid, port, protocol version, token
fingerprint, served-profile set).

That is exactly what we want here, and it is one systemd unit — the module's own:

```yaml
# profiles/default/config.yaml (the default profile only)
gateway:
  multiplex_profiles: true
```

The default profile's gateway becomes the host multiplexer and serves every enabled
profile; profiles created later are picked up live without a restart. Per-profile
lifecycle is `hermes -p coding gateway stop|start` (parking/unparking via a
`gateway.parked` marker), not a second process. Sessions are namespaced
`agent:<profile>:…` so two profiles on the same platform never collide.

**Footgun:** the module's `ExecStart` is `hermes gateway run --replace`, and issue
#119837 reports that `--replace` skips the host-lock refusal — a supervised unit that
loses a start race can run a second gateway beside the multiplexer. With a single unit
this is unlikely; verify `hermes gateway status` reports one owner after boot.

### 7.5 moshi-hook per profile

`moshi-hook install` writes into `$HERMES_HOME/.hermes/config.yaml` — i.e. into
*whichever* home `HERMES_HOME` points at. Four profiles means four installs, and four
copies of the mixed-indent corruption footgun that `hermes-config-check` exists to
repair (AGENTS.md §6; `hosts/hermes/moshi-hook.nix`).

- `plugins.enabled = ["moshi-hooks"]` stays **declarative per profile** in Nix.
- `moshi-hook install` runs once per `(profile, moshi-hook version)` pair, guarded by a
  per-profile stamp file, with `HERMES_HOME` set to that profile's directory.
- `hermes-config-check` repairs every profile's file afterwards (§7.2).
- Pairing (`moshi-hook pair --token`) is per host, not per profile, and stays a single
  oneshot. `modules/moshi-hook-user.nix` runs the hook daemon in the `hermes` user's
  manager — one instance, which is what `linger = true` in §5.1 is for.

**Blocker — the moshi token is not encrypted to this host.**
`secrets/secrets.nix:69` lists `moshi-device-id.age` recipients as
`[… hostDevelopment hostZeroclaw]` — **`hostHermes` is absent**, while
`hosts/hermes/configuration.nix:393` declares `age.secrets.moshi-device-id`. agenix
fails that secret softly (AGENTS.md: a decrypt failure records status and never aborts
the loop), and the pair script's own fallback is `"moshi-device-id secret unreadable,
skipping"` — which exits 0. The net effect is a host that never pairs, silently. Since
moshi-hook is a primary interface, fix this first (§11).

Also unresolved and noted in the current config: it is **unverified whether one Moshi
account token can pair three hosts** (development, zeroclaw, hermes) simultaneously.
Verify on the rebuilt host before assuming push works.

## 8. Cron

Cron is one of the two reasons the gateway runs at all (the dashboard is the other):

- **Jobs are per profile**: `profiles/<name>/cron/jobs.json`, with that profile's model,
  keys, SOUL and memory.
- **One ticker drives them all.** The multiplexer's 60 s tick serves every profile
  (§7.4) — no extra unit, no per-profile timer.
- **Runs are unattended and fresh**: each job gets a new session with no human present.
  Keep `platform_toolsets.cron` lean — upstream warns that heavy toolsets
  (browser/delegation) bloat the tool-schema prompt on *every LLM call of every job* —
  and note that `cronjob` is force-disabled inside cron runs (anti-recursion guard),
  while per-job `enabled_toolsets` on `cronjob.create` still overrides the default.
- **`approvals.cron_mode`** decides what happens when a cron run trips a dangerous
  command. Set it explicitly per profile (`deny` unless one specifically needs
  otherwise); see findings §4.3 for how it relates to `approvals.mode = "smart"` and
  `unattended_mode`.
- **Stateful jobs** (0.21.0): jobs carry persistent memory between runs and can skip the
  LLM call entirely when nothing changed. Worth using for anything polling.

### 8.1 Delivery

Upstream now delivers the agent's final response itself — "the agent does not send
messages itself, so there is nothing to call in the cron prompt". Each job stores a
`deliver` target; supported values include `homeassistant`, `webhook`, `origin`, `local`
and `platform:chat_id` forms. Delivery is tracked **separately from execution**: a run
whose output never landed records `last_status: delivery_failed` with
`last_delivery_error`, instead of a green `ok`.

Two candidate paths for a moshi-first host, and they are not equivalent:

1. **The moshi-hooks plugin fires on the run's own events.** If the hooks installed into
   each profile (§7.5) also fire for unattended cron sessions, the phone gets a push with
   no `deliver` target at all. This is the outcome to want — **verify it before building
   anything else**, with a one-minute throwaway job.
2. **`deliver: homeassistant`** (or a `webhook` at HA/ntfy), which is what today's
   hand-written `cron-result-delivery` skill does by hand via `hamcp_call_service`.
   Use this if (1) turns out not to cover cron runs.

Either way the hand-rolled skill goes: it exists only because the old version had no
delivery path, and it cannot report a failed delivery. With four profiles, whichever
path is chosen must make it obvious *which* profile a push came from.

## 9. Access Path

1. **mosh/ssh, over the tailnet or the LAN.** `modules/common.nix` enables
   `programs.mosh` and opens udp 60000–61000. The firewall is explicit per port and
   **`trustedInterfaces` is gone** — see §9.2, which is what keeps the dashboard's only
   door the authenticated one.
2. **`ssh hermes@homelab-hermes`**, then `hermes -p <profile> chat` or the per-profile
   `~/.local/bin/<name>` wrapper. One account, four agents.
3. **moshi-hook** for push out of agent sessions (§7.5) and, ideally, cron runs (§8.1).
4. **The web dashboard** at `hermes-dashboard.homelab.internal` (§9.1).

Nothing agent-related goes near `amadeus`: that account is in wheel with passwordless
sudo on every host, and these agents run shells — `coding` shells out to *other* agents.
Same reasoning as the split on `development` on 2026-09-14.

Optionally import `modules/herdr.nix` so a reconnecting mosh session lands back in a
persistent workspace instead of a bare shell.

### 9.1 Web dashboard — `hermes-dashboard.homelab.internal`

`hermes dashboard` serves a Vite/React UI (`nix/web.nix` builds it), default
`127.0.0.1:9119`, flags `--port`, `--host`, `--no-open`, `--isolated`. The NixOS module
exposes it declaratively as `backend.mode = "dashboard"` with
`backend.{host,port,waitFor,sessionTokenFile,extraArgs}`.
([docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard))

**One machine-level dashboard manages every profile** — a profile switcher in the
sidebar, selection carried in the URL as `?profile=<name>`. That is precisely why §5
keeps one unix user: the dashboard enumerates *the invoking user's* `profiles/`
directory. (`--isolated` would give a dedicated per-profile server instead; not wanted
here.)

**The bind address decides whether there is any authentication at all.** On a loopback
bind the dashboard skips its auth gate entirely; on a non-loopback bind it engages the
gate and refuses to start until an auth provider is configured. A Caddy vhost proxying
to `127.0.0.1:9119` would therefore serve an **unauthenticated** dashboard — full agent
control, including the terminal tool — to anything that reaches the vhost. So bind
non-loopback and let Hermes do the OIDC.

```nix
services.hermes-agent.backend = {
  mode = "dashboard";
  host = "0.0.0.0";     # non-loopback → the auth gate engages
  port = 9119;
};
```

```yaml
# profiles/default/config.yaml
dashboard:
  oauth:
    provider: self-hosted
    self_hosted:
      issuer: https://pocketid.dropbear-butterfly.ts.net
      client_id: hermes-dashboard
      scopes: "openid profile email"
  public_url: "https://hermes-dashboard.homelab.internal"
  trusted_proxies:
    - "127.0.0.1"          # Caddy, same host
```

Pocket ID is already this homelab's OIDC provider (forgejo, harbor, open-webui, romm,
pgadmin and grafana all point at that issuer), so this is a new **public PKCE client** —
`client_id` only, **no client secret**, therefore no new agenix entry. Register it in
Pocket ID with the callback under `public_url`, and restrict the client to your own user
or group: **authorization is not per profile** — anyone who logs in reaches every
profile, `coding`'s terminal included.

Env-var overrides exist if the config route proves awkward:
`HERMES_DASHBOARD_OIDC_ISSUER`, `HERMES_DASHBOARD_OIDC_CLIENT_ID`,
`HERMES_DASHBOARD_OIDC_SCOPES`, `HERMES_DASHBOARD_PUBLIC_URL`.

The Caddy vhost:

```nix
services.caddy.virtualHosts."hermes-dashboard.homelab.internal hermes-dashboard.homelab.local" = {
  extraConfig = ''
    tls {
      ca https://ca.homelab.local:8443/acme/acme/directory
    }
    handle {
      reverse_proxy 127.0.0.1:9119
    }
  '';
};
```

Three details that bite:

- **`127.0.0.1`, never `localhost`.** `/etc/resolv.conf` on these hosts lists a dead
  `nameserver ::1`, and every `reverse_proxy localhost:…` vhost hung on that timeout.
- **A non-loopback bind is reachable outside Caddy — unless the firewall says
  otherwise.** This is exactly why §9.2 drops `trustedInterfaces`: 9119 must never
  appear in any allow list, on any interface. The OIDC gate still stands in front of it
  (it is bound to the listener, not to the proxy), but the firewall is what makes the
  vhost the *only* path, so a future config slip in one layer is not a bypass on its
  own.
- **DNS and certs.** Add `hermes-dashboard.homelab.internal` (and `.local`) to
  `hosts/dns/configuration.nix` at 192.168.2.155, alongside the existing `hermes.*`
  records, and keep `modules/step-ca-trust.nix` imported.

### 9.2 Firewall — no bypass path

**The current `trustedInterfaces = ["tailscale0"]` is the bypass.** It accepts *every*
port from the tailnet, so the moment the dashboard binds `0.0.0.0:9119` (§9.1), anyone
on the tailnet reaches it directly — past Caddy, past the vhost, past TLS. The OIDC gate
would still challenge them, but a single door with two locks beats two doors with one
each. Every other host in this repo sets that line; hermes is the one that should not,
because it is the one running an agent with a shell.

```nix
networking.firewall = {
  enable = true;
  # NO trustedInterfaces. Nothing is open by virtue of which interface it arrived on.
  allowedTCPPorts = [
    22    # ssh / mosh handshake
    443   # Caddy: the dashboard vhost, and nothing else
    9100  # node exporter (otel scrapes from 192.168.2.135)
  ];
  allowedUDPPortRanges = [
    { from = 60000; to = 61000; }   # mosh
  ];
  # tailscaled's own inbound port: without it, direct connections fail and every
  # session is relayed through DERP. Not a hole — it is wireguard.
  allowedUDPPorts = [config.services.tailscale.port];
};
```

Deliberately absent, and the reason each is absent:

| Port | Why it is not listed |
| --- | --- |
| 9119 | the dashboard. Reachable **only** from `127.0.0.1`, i.e. only through Caddy. This is the whole point. |
| 8642 | the api_server. Gone entirely (§1) — no key, no vhost, no listener. |
| anything else | there is nothing else; the agent makes outbound connections, it does not serve. |

Two more layers behind it:

- `networking.firewall.checkReversePath = "loose"` comes from `modules/tailscale.nix`
  and must stay — tailscale needs it.
- Tailscale ACLs gate ports *before* the host firewall ever sees them, and they live
  outside this repo. Treat them as a bonus, never as the control: the host firewall must
  stand on its own, which is what the config above does.

### 9.3 Can Tailscale come off this node?

Reachability says yes; dependencies say no, not yet.

**Inbound is already covered without it.** `hosts/dns/configuration.nix` advertises
`--advertise-routes=192.168.2.0/24` from the dns host, and the `homelab.internal` zone
carries an A record per host at its LAN address — including
`hermes.homelab.internal. A 192.168.2.155`. That is the split-DNS path the phone already
uses, and it works through the subnet router whether or not hermes itself is on the
tailnet. Deploys do not need it either: hermes' colmena entry targets
`hermes.homelab.local` and has no `hostAddrs` entry, so `DEPLOY_NET=tailscale` never
switched it over.

**Two outbound dependencies are tailnet-only, and one of them is the dashboard's auth.**

- **Pocket ID is `pocketid.dropbear-butterfly.ts.net` and has no `homelab.internal`
  record** — it is not defined anywhere in this repo, so it is an external service
  reachable only over the tailnet. The dashboard's OIDC needs *server-side* reach to
  that issuer (discovery, JWKS), and on a non-loopback bind it "refuses to start until
  an auth provider is configured". Dropping Tailscale therefore breaks §9.1 outright.
- **`ventara-gateway`**, registered by `modules/coding-harness.nix`, is
  `https://ventara-vm01.dropbear-butterfly.ts.net:8093/mcp`. Without the tailnet that
  MCP server simply fails to connect. (`axon-gateway` is fine — it is
  `axon.homelab.local`.)

So: **keep Tailscale, drop the blanket trust.** That gets the security property you
actually asked for — no port is open merely because it arrived on `tailscale0` — without
breaking OIDC. Removing Tailscale entirely becomes possible if Pocket ID gets a
`pocketid.homelab.internal` record with a matching certificate, but note the issuer URL
is part of token identity, so changing it affects every other consumer (forgejo, harbor,
open-webui, romm, pgadmin, grafana) — not a hermes-local decision.

## 10. Memory — Requirement vs. What We Ship Now

**The requirement — self-hosted memory shared across profiles — is not met by this
rebuild, deliberately.** Recording it so the gap stays visible.

Hermes ships eight external memory providers. Their isolation model is *per profile by
default* — "each provider's data is isolated per profile", because each profile is a
separate home and the provider config lives in that home:

| Provider | Hosting | Infra needed | Cross-profile sharing |
| --- | --- | --- | --- |
| Holographic | local only | SQLite (+ NumPy for HRR) | no — one DB per home |
| ByteRover | local or cloud | local store `$HERMES_HOME/byterover/` | no — profile-scoped |
| **Honcho** | cloud **or self-hosted** | API + Deriver + Postgres/pgvector + Redis + an OpenAI-compatible LLM | **yes — native, shared `workspace` with one peer per profile** |
| Supermemory | cloud or self-hosted | own server | partial — multi-container mode, `enable_custom_container_tags` |
| Mem0 | cloud, self-hosted (Docker) or OSS | server or LLM + vector store | partial — via a shared `user_id`/`agent_id` |
| Hindsight | cloud or local | Postgres + LLM | not documented |
| OpenViking | self-hosted only | own server, no external DB | per-profile `.env` |
| RetainDB | cloud only | managed | no — auto profile-scoped projects |

**Now: holographic, per profile.** Two cheap mitigations that get part of the way to a
shared store without new infrastructure:

- The holographic provider takes a `db_path` config key. With every profile under one
  uid (§5), pointing several of them at one SQLite file under `~/.hermes/` is trivial —
  no shared group, no permissions work. Treat it as experimental all the same:
  upstream's warning is about two agents sharing a *home*, not a *DB*, and SQLite/WAL
  tolerates multiple processes, but nothing upstream promises this. Cron runs (§8) mean
  "they never run concurrently" is not a safe assumption.
- Raise `memory.memory_char_limit` / `user_char_limit` further (the current host is
  already at 4× the module defaults, 8800/5500). This addresses "the memory is small"
  only in how much is injected into the prompt — it is not retrieval.

**Later: self-hosted Honcho.** It is the only provider with native cross-profile
sharing — it
models conversations as peers in a shared `workspace`, one user peer plus one AI peer
per profile, with config resolution `host block > root > env > default`. Config keys:
`apiKey`, `baseUrl`, `workspace`, `peerName`, `aiPeer`, plus per-host `recallMode`
(`hybrid`/`context`/`tools`) and `sessionStrategy`. Self-hosting runs API + Deriver +
Postgres/pgvector + Redis and routes LLM calls through any OpenAI-compatible endpoint
(the DeepSeek key qualifies). Placement — the hermes VM itself versus
`hosts/containers` + `hosts/database` (which needs pgvector added to `postgresql_18`
and a Redis) — is a separate plan.

## 11. Secrets

Recipients in `secrets/secrets.nix`, corrected for the new design:

| Secret | Action |
| --- | --- |
| `hermes-deepseek-key.age` | keep; likely split per profile (below) |
| `hermes-opencode-zen-key.age` | keep — now also the harness's `opencode-zen-key` (§6.2) |
| `hermes-agentmail-key.age` | keep (MCP carried over) |
| `hermes-forgejo-ssh.age` | **keep, re-minted** — the new `hermes` Forgejo account's own key (§5.2) |
| `hermes-forgejo-token.age` | **new**, optional — REST-API token for `fj`, only if `forgejo-cli.nix` is imported |
| `axon-gateway-env.age` | keep **and add `hostHermes`** — line 42 lists `hostMcp hostDevelopment hostOtel hostZeroclaw` only; the harness needs it too |
| `moshi-device-id.age` | **add `hostHermes`** — line 69 omits it (§7.5) |
| `ventara-gateway-env.age` | add if `ventara-gateway` MCP is wanted; `coding-harness.nix` registers it |
| `hermes-api-server-key.age` | delete — no api_server |

Both "add `hostHermes`" items are pre-existing breakage, not work created by this
rebuild: the config declares those secrets today and they cannot decrypt on that host.

**Per-profile keys.** A named profile resolves providers only from its own `.env`, so
giving profiles different providers means one agenix file per profile —
`hermes-coding-env.age`, `hermes-research-env.age`, `hermes-kb-env.age` — each holding
that profile's `DEEPSEEK_API_KEY` / `OPENCODE_ZEN_API_KEY`, all owned by `hermes`. The
rendering in §7.2 concatenates them into `profiles/<name>/.env`. Note this separates
*what each profile uses*, not *what it could read*: one uid owns them all (§5).

**No secret for the dashboard.** Its OIDC client is a public PKCE client — `client_id`
only (§9.1).

**Re-key sequence after the wipe** (nixos-anywhere generates a fresh host key, so every
hermes secret fails to decrypt until this is done — AGENTS.md "Reprovisioned Host"):

```bash
just get-host-key 192.168.2.155     # or: ssh-keyscan -t ed25519 192.168.2.155
# update hostHermes in secrets/secrets.nix, and add it to axon-gateway-env +
# moshi-device-id while you are in there
just reencrypt                       # agenix -r
```

Hermes is also a Tailscale node, so the new host key must be in the `users` list that
receives `tailscale-auth-key.age`.

## 12. Cross-Host Cleanups

- **`hosts/containers/open-webui/default.nix`** — `OPENAI_API_BASE_URLS` (line 94)
  includes `https://hermes.homelab.local/v1`, and the surrounding comments describe
  hermes as a model backend reachable with the API server key. Remove the hermes entry
  and the key slot from the commented `open-webui-env` layout, leaving the wotan vLLM
  endpoint. Dropping the api_server without this leaves Open WebUI with a dead backend.
- **`hosts/dns/configuration.nix`** — keep the `hermes.homelab.{local,internal}` A
  records at 192.168.2.155 (still wanted for ssh/mosh) and the hosts-file entry, and
  **add `hermes-dashboard.homelab.internal`** at the same address (§9.1). There is no
  `pocketid.*` record in this zone; adding one is the prerequisite for ever taking
  Tailscale off this node (§9.3), and it is a fleet-wide change, not a hermes one.
- **`hosts/otel/*`** — the hermes blackbox probes were already removed on 2026-09-10;
  the `hermes-node` scrape job can come back once the host is up, since node exporter
  on 9100 stays.
- **`flake.nix`** — uncomment the `hermes` entry in `colmenaHive` (disabled 2026-09-09
  for "No route to host"). Until then only `nix eval` / `just deploy` reach this host,
  and `just cah hermes` does not work.
- **Forgejo** — create the `hermes` account, register its new SSH key, give it
  collaborator access to every repo the `coding` profile should touch, and add it to
  the push whitelist on each protected `main` (§5.2, §5.2.1). Retire `hermes-bot`.
- **`AGENTS.md` §7** — rewrite. It documents the superseded feature-branch workflow,
  the `~/workspace/pve-nixos-homelab` checkout, the `homelab-config-repo` skill, and
  branch protection as the thing that stops the bot landing changes. Replace it with
  the §5/§6 shape: agent account, `repo-sync` under `~/code`, harness, pushes `main`.

## 13. Cutover Runbook

1. `just iso-build`, upload the ISO to the `local` datastore, and update **both**
   existing `file_id` strings that reference it (dns, ca) plus the new hermes one.
2. Edit `iac/main.tf` (§2). `tofu plan` and confirm: hermes disk replaced, `vm_id`
   unchanged, no other guest touched. `tofu apply`.
   **First check whether there is anything to wipe**: `todo/comin-removal-cleanup.md`
   lists hermes under "Unreachable + decommissioned (VMs no longer exist)", while the
   `hermes_vm` resource is still in `iac/main.tf` with `started = false`. If the guest
   is already gone in Proxmox this is a create, not a replace, and the plan output
   will say so.
3. Boot the VM from the ISO; note its DHCP address.
4. `just deploy hermes <ip> --phases disko,install,reboot` — skips kexec because the
   ISO is already an installer. This is the destructive step; the old 256 GB zvol is
   gone at this point.
5. Re-key secrets (§11). Nothing agenix-backed works before this.
6. Uncomment the hive entry (§12) and `just cah hermes`.
7. Post-install manual steps that cannot be declarative:
   - `claude login` as the `hermes` user (§6.2), if Claude Code is to be used.
   - Pocket ID: register the `hermes-dashboard` public client with the callback under
     `public_url`, restricted to your own user/group (§9.1).
   - Forgejo web UI: create the `hermes` account, register the new public key on it,
     grant collaborator access, and add it to the push whitelist on each protected
     `main` (§5.2, §5.2.1). Verify with a throwaway commit pushed from the host before
     trusting the `coding` profile with real work.
8. Verify, in this order:
   - `systemctl status hermes-config-check` → active/exited, no "repaired" surprises.
   - `journalctl -u hermes-agent -b | grep -c 'Falling back to default config'` → 0.
   - `hermes gateway status` → exactly one owner (§7.4).
   - `hermes profile list` → all four, each with its own model.
   - `hermes plugins compat …/profiles/<n>/plugins/moshi-hooks` → exit 0 per profile
     (findings §3.1).
   - `https://hermes-dashboard.homelab.internal` → **redirects to Pocket ID**, and after
     login the sidebar switcher lists all four profiles. If it ever renders the UI with
     no login, the bind went back to loopback — stop and fix §9.1.
   - From the phone, on the tailnet: `curl -m5 http://hermes.homelab.internal:9119`
     → **connection refused/timeout**, while 443 works. If 9119 answers, the firewall
     still trusts an interface (§9.2) and there is a bypass.
   - `ss -ltnp` on the host → 9119 bound, 8642 absent, nothing else listening beyond
     22/443/9100.
   - `moshi-hook status --json | jq .paired` → `true`, and a test notification lands on
     the phone (§7.5).
   - `sudo -u hermes -i`, then `opencode run "print the repo name"` in a `~/code`
     checkout → completes, and `claude -p` likewise if logged in.
   - In `hermes -p coding chat`: make a scratch edit, then `/rollback` restores it
     (§7.3).
   - A throwaway one-minute cron job on one profile → runs, and the result reaches the
     phone by whichever path §8.1 established.
   - `mosh hermes@homelab-hermes` from the phone → `hermes -p coding chat` starts.
9. Only then remove the hermes backend from Open WebUI (§12) — the last thing still
   pointed at the old interface.

## 14. Open Questions

- **Do moshi hooks fire on unattended cron runs?** (§8.1) Decides whether cron needs a
  `deliver` target at all.
- **Claude Code credentials for unattended use** (§6.2). opencode has an agenix key;
  Claude Code appears to need an interactive login, which does not suit cron.
- **Does `user` + `createUser = false` + a `/home` `stateDir` work on `v2026.9.21`?**
  (§5.1) Read from the module source, not exercised.
- **Does Pocket ID issue public PKCE clients?** (§9.1) Every existing homelab client
  (forgejo, harbor, pgadmin) uses a client *secret*; the dashboard wants a secret-less
  PKCE client. Confirm in Pocket ID before assuming no agenix entry is needed.
- **Is a `pocketid.homelab.internal` record worth adding?** (§9.3) It is what would let
  hermes — and eventually other nodes — stop depending on the tailnet for auth. Fleet-wide
  change: the issuer URL is part of token identity.
- **Do the harness modules get proper options?** (§6) They read `homelab.agent.*`, which
  no longer describes this host; `enable = false` + a repointed `user` works but is a
  lie in the option name.
- **`hermesHomeFiles` vs `documents`** for SOUL.md on the new version (findings §3.2) —
  affects §7.3's activation script and the `ReadOnlyPaths` list. Check before writing
  the module.
- **Which profiles get which provider/model**, and therefore how many per-profile
  secrets to create (§11). The table in §7.2 is a starting proposal.
- **Is a `default` profile worth it**, or should `coding` own the multiplexer and the
  dashboard? A thin default keeps their overhead off a working profile, at the cost of a
  fourth home.
- **Does one Moshi token pair three hosts?** Unverified, and this rebuild makes hermes
  the host where it matters most (§7.5).
