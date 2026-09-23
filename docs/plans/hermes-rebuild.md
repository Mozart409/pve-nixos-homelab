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
- Profiles `coding`, `research`, `kb` — separate `config.yaml`, `.env`, `SOUL.md`,
  memory, sessions, checkpoints and **cron jobs** per profile (§7, §8).
- **One unprivileged unix user per profile, each with its own home** (§5) — the
  isolation boundary is the kernel, not Hermes' bookkeeping.
- A Forgejo account of the host's own, `hermes`, with its own SSH key, held by the
  `coding` user only and pushing `main` directly (§5.1, §5.4), with `repo-sync` keeping
  its `~/code` checkouts current.
- The web dashboard at `hermes-dashboard.homelab.internal` (§9.1), and per-profile
  checkpoints/rollback for `coding` (§7.5).
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

## 5. Users — One Per Profile

**No `homelab.agent` account here.** `modules/agent-user.nix` exists to split one
workstation between a human (`amadeus`, wheel) and one unattended agent; on this host
there is no human workload to separate from, every login *is* an agent, and the unit of
isolation is the profile, not the machine. Importing it would create one shared account
that all profiles write into — the opposite of what we want.

Instead: **one unix user per profile, each with its own home.** That makes the kernel,
not Hermes' own bookkeeping, the thing keeping `coding` out of `research`'s memory,
sessions, keys and checkouts.

| Profile | Unix user | Home | Logs in? | Git? |
| --- | --- | --- | --- | --- |
| `coding` | `coding` | `/home/coding` | yes (mosh) | yes — Forgejo key |
| `research` | `research` | `/home/research` | yes (mosh) | no |
| `kb` | `kb` | `/home/kb` | yes (mosh) | no |

What the dropped module was providing, and where each piece goes instead:

- **No sudo.** Free: these are plain accounts, not in wheel. Keep the explicit
  `security.sudo.extraRules` `!ALL` deny that `agent-user.nix` uses, applied to the
  whole set, so a later `extraRules` cannot quietly widen it.
- **SSH login.** Put `config.homelab.users.amadeus.sshKeys` in each user's
  `openssh.authorizedKeys.keys`, so the phone reaches any profile directly:
  `mosh coding@homelab-hermes`.
- **`linger = true`** per user — required if the gateways are systemd *user* services
  (§5.2), and harmless otherwise.
- **The Forgejo `Match` block.** `agent-user.nix` wrote it; write it in the host config
  instead, scoped to the one user that has git (§5.1).

### 5.1 The Forgejo identity

Unchanged by the user split: **one Forgejo account for this host, named `hermes`, with
its own SSH key.** Forgejo resolves the account from the key fingerprint, so one public
key belongs to exactly one account, and a per-host key is what keeps revocation and
attribution per-host.

| Thing | Value |
| --- | --- |
| Forgejo account | `hermes` / `hermes@homelab.local`, unrestricted, **not** admin |
| SSH key | fresh ed25519, registered on that account as `homelab-hermes` |
| Private key | agenix `secrets/hermes-forgejo-ssh.age`, `0400` **to the `coding` user** |
| Commit identity | `user.name = hermes`, `user.email = hermes@homelab.local` |
| API token (optional) | `secrets/hermes-forgejo-token.age`, scopes `write:repository,write:user` |

`todo/forgejo-bot-account-development.md` is the working recipe (it is how
`developmentbot` was created). Two details:

- **`hermes-forgejo-ssh.age` is re-minted, not reused.** It holds the *`hermes-bot`*
  account's key today — the account that served the Obsidian vault and the
  feature-branch flow, both dropped here. Generate a new keypair, `agenix -e` the
  private half into that filename, and retire `hermes-bot` (rename it to `hermes` to
  keep its past commits attributed, or delete it once nothing references it).
- **Only the `coding` user gets the key**, via the ssh config block and the secret's
  owner. `research` and `kb` have no reason to push anything, and with separate unix
  users that is now enforced rather than merely intended.

```nix
programs.ssh.extraConfig = ''
  Match user coding host forgejo.homelab.local,forgejo.homelab.internal
    Port 2222
    User forgejo
    IdentityFile ${config.age.secrets.hermes-forgejo-ssh.path}
    IdentitiesOnly yes
    IdentityAgent none
    StrictHostKeyChecking accept-new
'';
```

It pushes `main` directly — see §5.4.

### 5.2 How this works in NixOS

Three viable patterns. All three give each profile its own home; they differ in where
the unit lives and what hardening survives.

**A. Generated system services (recommended).** Keep one attrset of profiles in Nix and
map it into users and units:

```nix
let
  profiles = {
    coding   = { model = "deepseek-v4-pro";   secrets = [ ... ]; };
    research = { model = "deepseek-v4-pro";   secrets = [ ... ]; };
    kb       = { model = "deepseek-v4-flash"; secrets = [ ... ]; };
  };
in {
  users.users = lib.mapAttrs (name: _: {
    isNormalUser = true;
    home = "/home/${name}";
    group = "hermes";
    linger = true;
    openssh.authorizedKeys.keys = config.homelab.users.amadeus.sshKeys;
  }) profiles;
  users.groups.hermes = {};

  systemd.services =
    lib.mapAttrs' (name: cfg:
      lib.nameValuePair "hermes-${name}" { /* User = name; ExecStart = …; */ })
    profiles;
}
```

`lib.mapAttrs'` over an instance set is the idiomatic NixOS multi-instance pattern —
[nixcloud/minimal-example](https://github.com/nixcloud/minimal-example) is the canonical
demonstration. It beats a systemd template unit (`systemd.services."hermes@"` with `%i`,
instantiated via `systemd.targets.multi-user.wants`) here because each instance needs
*different* values — its own `EnvironmentFile`, `ReadOnlyPaths` and model — which `%i`
cannot express.

**Why system services and not user services: the network allow-list.** The current
unit's `IPAddressDeny` / `IPAddressAllow` pair (added 2026-09-14) is what confines an
agent with a shell and web tools to five LAN peers. `IPAddress*` is a cgroup BPF filter
applied by the system manager; in a systemd **user** unit it generally requires
delegation and is commonly ineffective. `ProtectSystem=strict`, `ReadOnlyPaths` and the
resource caps are likewise system-manager territory. Verify before choosing B.

**B. The upstream home-manager module.** Upstream ships `nix/homeManagerModules.nix`,
a good fit on paper: `programs.hermes-agent.enable` (CLI + `HERMES_HOME`),
`services.hermes-agent.{enable,gateway.enable,hermesHome,settings,…}`, `HERMES_HOME`
defaulting to `${config.home.homeDirectory}/.hermes`, and a
`systemd.user.services.hermes-agent` unit generated on Linux when `gateway.enable`. It
has no user/group options — it runs as the invoking user, which is exactly the
per-profile model. This repo already wires home-manager (`homeManagerNixvim`,
`home-manager.users.amadeus`), so it would be `home-manager.users.<profile>.imports`.
The cost is the hardening above.

**C. The NixOS module, once.** `services.hermes-agent` is a singleton — one `user`, one
`stateDir` — so it can serve at most one profile. Use it for one and hand-roll the rest
from `hermes-agent.packages.${system}`, or don't use it at all.

Whichever is picked, the per-user pieces are the same: agenix secrets with
`owner = <profile user>`, a `moshi-hook-user.nix` instance per user (§7.4), and
`services.openssh` untouched (logins are by key, per user).

### 5.3 What this costs on the Hermes side

Separate unix users is a supported shape upstream — issue #109954 calls it a
"privilege-isolated fleet" — but it is **off the paved path**, and the paved path is
moving the other way. Know these before committing:

- **Each user runs its own *default* profile.** There is no `~/.hermes/profiles/`
  subdirectory, no `hermes -p`, no named secondaries. That is what makes the split
  clean — the multiplexer, the `/p/<name>/` URL prefixes and the `--force` refusals
  (`hermes -p X gateway install/start/run` refuses when `User=` differs from the default
  gateway's, or when `HERMES_HOME` is outside the default home's `profiles/`) never come
  up. Do not mix the two models.
- **The host-wide singleton lock is the thing to verify first.** `v2026.9.21` added a
  per-role flock plus a published rendezvous record, and one *host* gateway is the
  stated design. Whether that lock root is per-home or genuinely host-global decides
  whether three gateways under three uids coexist or fight. Issue #109954 describes five
  such gateways running in production, so it works — but confirm on our version before
  building around it. **The same question decides the dashboard (§9.1).**
- **Upstream is deprecating this.** Issue #109417 tracks "profile multiplexing as the
  only gateway mode". A future release may remove the per-user shape; the escape hatch
  would be `gateway.standalone: true` (PR #119680) per profile.
- **`hermes update` would collapse it.** Issue #109954:
  `maybe_auto_migrate_after_update()` uninstalls secondary units without confirmation,
  folding a multi-user fleet into one process under the default user. On NixOS this is
  mostly moot — the package is a read-only store path and updates come from the flake —
  but the rule is simply: **never run `hermes update` on this host.**
- **Cross-profile anything gets harder**, memory included (§10). Session search,
  `hermes profile list/clone/export` and shared skills stop being cross-profile, because
  from Hermes' point of view these are three unrelated machines that share a kernel. A
  shared group (`users.groups.hermes`) plus a group-writable directory is the lever if
  something genuinely needs sharing.

### 5.4 Repo checkouts and pushing `main`

Only the `coding` user gets git:

```nix
homelab.repoSync.coding = {
  sshKey = config.age.secrets.hermes-forgejo-ssh.path;
  push   = true;
};
```

`modules/repo-sync.nix` then walks every checkout under `~/code` on a timer: fetch →
`merge --ff-only` (refuses on divergence) → plain `push` (no `--force`, ever). It never
commits or rebases, and exits 0 on every skippable state, so a dirty tree is not a
failure. That is how commits reach Forgejo without a human step, and it is what the
`coding` profile operates on: clones under `/home/coding/code`.

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
  ../../modules/coding-harness.nix
  ../../modules/claude-permissions.nix
  ../../modules/claude-settings-verify.nix
  ../../modules/repo-sync.nix
  ../../modules/moshi-hook-user.nix
  ../../modules/forgejo-cli.nix      # optional: `fj` for repo creation over REST
  # ../../modules/herdr.nix          # optional: terminal workspace for mosh sessions
];
```

**These modules read `config.homelab.agent.{user,home}`, which no longer describes this
host.** The options themselves are declared unconditionally in `modules/agent-user.nix`
— only its `config` block is gated behind `homelab.agent.enable` — so the workable form
is: import `agent-user.nix` for its options, leave `enable = false` (no account
created), and point the harness at the one user that needs it:

```nix
homelab.agent.enable = false;      # no shared agent account on this host
homelab.agent.user   = "coding";   # who the harness modules configure
homelab.agent.home   = "/home/coding";
```

That is a small abuse of an option named `agent`; the honest alternative is to give
those modules their own `homelab.codingHarness.{user,home}` options defaulting to
`homelab.agent.*` for `development`. Either way the harness targets **one** user —
`research` and `kb` get no `~/.claude`, no opencode config and no MCP wiring, which is
consistent with them having no git.

`modules/coding-harness.nix` renders, for that account: Claude Code's
`~/.claude/settings.json` (MCP servers as `type = "http"` with `${VAR}` header
expansion), opencode's `~/.config/opencode/` (same servers as `type = "remote"` with
`{env:VAR}`), the repo's skills from `.opencode/skills/` symlinked into
`~/.claude/skills/` (read by *both* tools), and the slash-commands from
`.opencode/command/`. MCP servers come from one list in that module — `axon-gateway` and
`ventara-gateway` — so hermes inherits both by importing it.

### 6.1 What Hermes actually runs

Hermes' `terminal` toolset (backend `local`) executes as the profile's own user, so for
`coding` the harness is simply on its PATH. That profile's SOUL.md directs it to shell
out rather than edit directly, e.g. `opencode run "<task>"` inside
`/home/coding/code/<repo>`, or `claude -p "<prompt>"`. Consequences worth writing into
the config comments:

- **Guardrails come from the harness, not from Hermes.** Hermes' approval layer sees one
  `opencode` invocation; everything the nested agent then does is governed by
  `modules/claude-permissions-data.nix` and the `opencodePermissions` block — plus the
  unprivileged account, which is the only real boundary.
- **Resource caps must be raised.** The current unit sets `MemoryHigh = 3G`,
  `TasksMax = 512`, `LimitNPROC = 512`. A nested node/opencode process plus a
  `nix develop` will exceed that. Raise or drop `MemoryHigh` (the existing comment
  already explains why there is deliberately no `MemoryMax`) and lift the task caps —
  for the `coding` unit specifically; `research` and `kb` can stay tight.
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
  `age.secrets.opencode-zen-key`. Declare it pointing at the existing file, owned by the
  `coding` user:

  ```nix
  age.secrets.opencode-zen-key = {
    file  = ../../secrets/hermes-opencode-zen-key.age;
    owner = "coding";
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

### 7.1 What a profile is here

Upstream's own notion of a profile — `$HERMES_HOME/profiles/<name>/`, selected with
`hermes -p` — is **not** what this host uses (§5.3). Each profile is a separate unix user
running its own *default* Hermes home at `~/.hermes`: its own `config.yaml`, `.env`,
`SOUL.md`, `memories/`, `sessions/`, `skills/`, cron jobs, checkpoints and `state.db`,
owned by a different uid.

That satisfies the same requirement — different API keys, models and personalities per
profile, with no bleed — and does it at the kernel level. Upstream's own hard rule
("never point two agent processes at the same Hermes home") is then enforced by file
permissions rather than by discipline.

### 7.2 The profiles

| Profile | Purpose | Model | Toolsets | Harness |
| --- | --- | --- | --- | --- |
| `coding` | drives opencode/claude in `~/code` | `deepseek-v4-pro` | file, memory, skills, terminal, code_execution, session_search, cronjob | yes |
| `research` | reading, synthesis | `deepseek-v4-pro` | file, memory, skills, web, session_search, cronjob | no |
| `kb` | notes / knowledge capture | `deepseek-v4-flash` | file, memory, skills, session_search, cronjob | no |

Keep each toolset list minimal: every enabled toolset costs tool-schema tokens on every
LLM call, and `browser` in particular should stay off until it has an engine (findings
§4.2). `coding`'s SOUL.md carries the validation rule — a scoped
`nix eval '.#nixosConfigurations.<host>.…drvPath'` per edited host, never the full
`nix flake check`, which evaluates ~16 hosts and gets OOM-killed.

### 7.3 Rendering each profile declaratively

Per profile, from the one `profiles` attrset in §5.2:

- Render `config.yaml` and `SOUL.md` into the Nix store (`pkgs.writeText`).
- An activation script installs them to `/home/<name>/.hermes/config.yaml` and
  `~/.hermes/SOUL.md` (**check which of `documents` / `hermesHomeFiles` upstream now
  reads the prompt from — findings §3.2**), `chown` to that user, and concatenates that
  profile's agenix secrets into `~/.hermes/.env` at mode 0600.
- Bind both files read-only in that profile's unit (`ReadOnlyPaths`) so the agent cannot
  rewrite its own prompt or model at runtime.

Two things to carry over from the current host:

- **The config.yaml integrity gate.** `hermes-config-check` exists because a malformed
  `config.yaml` makes Hermes fail *open* to built-in defaults (AGENTS.md §6). There are
  now N of them, in N homes — the check must run per profile, ordered before that
  profile's unit.
- **`secretNonce`.** Writing files at stable paths does not change a unit definition, so
  a deploy does not restart anything. Keep the nonce (or one per profile) and bump it
  when a profile's config, SOUL or secret changes.

### 7.4 moshi-hook per profile

`moshi-hook install` writes into `$HERMES_HOME/.hermes/config.yaml` — whichever home
`HERMES_HOME` points at. Three users means three installs, and three copies of the
mixed-indent corruption footgun that `hermes-config-check` exists to repair (AGENTS.md
§6; `hosts/hermes/moshi-hook.nix`).

- `plugins.enabled = ["moshi-hooks"]` stays **declarative per profile** in Nix.
- `moshi-hook install` runs once per `(user, moshi-hook version)` pair, guarded by a
  stamp in that user's home, with `HERMES_HOME` set accordingly.
- `hermes-config-check` repairs every profile's file afterwards (§7.3).
- Pairing (`moshi-hook pair --token`) is per host, not per user, and stays a single
  oneshot. `modules/moshi-hook-user.nix` runs the hook daemon in a user manager — it
  needs instantiating for each profile user, which is the same `linger = true`
  requirement as §5.

**Blocker — the moshi token is not encrypted to this host.**
`secrets/secrets.nix:69` lists `moshi-device-id.age` recipients as
`[… hostDevelopment hostZeroclaw]` — **`hostHermes` is absent**, while
`hosts/hermes/configuration.nix:393` declares `age.secrets.moshi-device-id`. agenix
fails that secret softly (AGENTS.md: a decrypt failure records status and never aborts
the loop), and the pair script's own fallback is `"moshi-device-id secret unreadable,
skipping"` — which exits 0. The net effect is a host that never pairs, silently. Since
moshi-hook is the primary interface, fix this first (§11).

Also unresolved and noted in the current config: it is **unverified whether one Moshi
account token can pair three hosts** (development, zeroclaw, hermes) simultaneously, let
alone three users on one host. Verify on the rebuilt host before assuming push works.

### 7.5 Checkpoints and rollback

Hermes can snapshot a project before destructive operations (file writes, patches,
`rm`/`mv`/`sed -i` in the terminal tool) into a shadow git store, and restore it with
`/rollback`. It is **opt-in — `enabled: false` is the default** — and it is worth
turning on for `coding`, which is the profile that edits files and shells out to other
agents. ([docs](https://hermes-agent.nousresearch.com/docs/user-guide/checkpoints-and-rollback#configuration))

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

What this means here specifically:

- **The store is per home, so it is per profile.** Three profiles means three stores and
  three independent `max_total_size_mb` budgets — 500 MB each is 1.5 GB worst case,
  which the 64 GB disk in §2 absorbs, but size it deliberately rather than by default.
  Enable it for `coding`; leave `research` and `kb` at `enabled: false`, since neither
  writes code.
- **`git gc` competes with the agent.** Reclaim runs on a background sweep (CLI launch,
  gateway housekeeping tick) and can take tens of seconds. It is deliberately
  non-blocking, but on a 4-core guest that also runs nested `opencode`, keep
  `min_interval_hours: 24`.
- **Checkpoints are not backups.** They cover the working directory of a project the
  agent touched, in a store that prunes itself on a 7-day retention. Forgejo remains the
  durable copy — which is the other reason `coding` pushes `main` (§5.4).
- **Container terminal backends skip it.** Not relevant now (`backend = "local"`), but
  worth a comment so a future move to a sandbox backend does not silently lose rollback.

## 8. Cron

Cron is the reason each profile keeps a running gateway. Its shape here:

- **Jobs are per profile because homes are per profile**: `~/.hermes/cron/jobs.json` in
  each user's home, invisible to the others.
- **Each profile's own gateway ticks its own jobs** every 60 s. There is no multiplexer
  and no shared ticker (§5.3) — three users, three gateways, three tickers. This rests
  on the host-lock question in §5.3; settle that first.
- **Runs are unattended and fresh**: each job gets a new session with no human present.
  Keep the cron toolset list lean — upstream warns that heavy toolsets
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

For a moshi-first host there are two candidate paths, and they are not equivalent:

1. **The moshi-hooks plugin fires on the run's own events.** If the hooks installed into
   each profile (§7.4) also fire for unattended cron sessions, the phone gets a push with
   no `deliver` target at all. This is the outcome to want — **verify it before building
   anything else**, with a one-minute throwaway job.
2. **`deliver: homeassistant`** (or a `webhook` at HA/ntfy), which is what today's
   hand-written `cron-result-delivery` skill does by hand via `hamcp_call_service`.
   Use this if (1) turns out not to cover cron runs.

Either way the hand-rolled skill goes: it exists only because the old version had no
delivery path, and it cannot report a failed delivery. With three profiles, whichever
path is chosen must make it obvious *which* profile a push came from.

## 9. Access Path

1. **mosh/ssh over Tailscale.** `modules/common.nix` already enables `programs.mosh` and
   opens udp 60000–61000, and `trustedInterfaces = ["tailscale0"]` covers the tailnet
   side. Firewall: `allowedTCPPorts = [22 443 9100]` — 443 comes back for the dashboard
   (§9.1), which is the only thing still needing Caddy.
2. **Log in as the profile you want.** Each profile user carries `amadeus`'s SSH keys,
   so the phone picks the agent by choosing the login: `mosh coding@homelab-hermes`,
   `mosh research@homelab-hermes`. No `-p` flag, no profile switching, no wrapper
   scripts — the account *is* the profile.
3. **moshi-hook** for push out of agent sessions (§7.4) and, ideally, out of cron runs
   (§8.1).

Nothing agent-related goes near `amadeus`: that account is in wheel with passwordless
sudo on every host, and these agents run shells — `coding` shells out to *other* agents.
That is the same reasoning behind the split on `development` on 2026-09-14; here it is
expressed as "amadeus simply has no Hermes home".

Optionally import `modules/herdr.nix` so a reconnecting mosh session lands back in a
persistent workspace instead of a bare shell.

### 9.1 Web dashboard — `hermes-dashboard.homelab.internal`

`hermes dashboard` serves a Vite/React UI (`nix/web.nix` builds it) on
`127.0.0.1:9119` by default; flags are `--port`, `--host`, `--no-open` and `--isolated`.
The NixOS module exposes the same thing declaratively as
`backend.mode = "dashboard"` with `backend.{host,port,waitFor,sessionTokenFile,extraArgs}`.
([docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard))

Serving it at `hermes-dashboard.homelab.internal`:

```nix
services.caddy.virtualHosts."hermes-dashboard.homelab.internal hermes-dashboard.homelab.local" = {
  extraConfig = ''
    tls {
      ca https://ca.homelab.local:8443/acme/acme/directory
    }
    handle {
      reverse_proxy 127.0.0.1:9119   # 127.0.0.1, never "localhost" — see below
    }
  '';
};
```

Four things this needs, in order of how badly they bite:

1. **Authentication is not automatic behind a proxy.** The dashboard skips its auth gate
   entirely on a loopback bind and only "engages an auth gate … refuses to start until an
   auth provider is configured" on a non-loopback one. Caddy terminating TLS and
   proxying to `127.0.0.1:9119` means the dashboard sees loopback and asks for **no
   login** — so anyone who can reach the vhost gets full agent control, including the
   terminal tool. Either put auth in front of it in Caddy (the homelab already runs
   Pocket ID, which `open-webui` uses as an OIDC provider), or bind the dashboard
   non-loopback and configure its own OIDC provider against Pocket ID, plus
   `dashboard.public_url` (OAuth callback) and `dashboard.trusted_proxies` (the CIDR
   whose `X-Forwarded-*` headers to trust). **Do not ship the loopback+proxy combination
   as-is.**
2. **One dashboard is one machine's worth of profiles — as that user sees them.** The
   docs describe a single machine-level dashboard with a sidebar profile switcher and
   `?profile=<name>` in the URL, managing "every profile on the machine". That
   enumeration is of the invoking user's `~/.hermes/profiles/`, and under §5 each profile
   is a *different uid with no `profiles/` subdirectory at all*. So one dashboard sees
   exactly one profile. This is the second feature after the gateway multiplexer that
   assumes the single-home model — see the fork below.
3. **`127.0.0.1`, not `localhost`.** `/etc/resolv.conf` on these hosts lists a dead
   `nameserver ::1`, and every `reverse_proxy localhost:…` vhost hung on that timeout.
   Use the literal address.
4. **DNS and certs.** Add `hermes-dashboard.homelab.internal` (and `.local` if wanted) to
   `hosts/dns/configuration.nix` pointing at 192.168.2.155, alongside the existing
   `hermes.*` records. The step-ca ACME vhost pattern is already in the current hermes
   config; `modules/step-ca-trust.nix` must stay imported.

**The fork.** Per-profile unix users and a single unified dashboard pull in opposite
directions, and both were explicit requirements:

- **(a) Keep per-user homes; run one dashboard per profile.** Three `hermes dashboard`
  instances on 9119/9120/9121, three vhosts
  (`hermes-dashboard.homelab.internal` → `coding`, plus one each for `research`/`kb`),
  or one vhost if only `coding` needs a UI. Isolation intact; the sidebar profile
  switcher is dead weight since each instance sees one profile.
- **(b) Single `hermes` user, profiles under `~/.hermes/profiles/`.** One dashboard with
  a working profile switcher at one hostname, one multiplexing gateway, `hermes -p` on
  the CLI — the upstream paved path, and the thing upstream is converging on (§5.3).
  Isolation drops back to file-permissions-within-one-uid, i.e. none.

**Recommend (a)**, with only `coding` exposed at first: the isolation was the point of
the user split, and a dashboard that shows one profile is a smaller loss than three
profiles sharing a uid. But this is a real trade and (b) is defensible — it is the
configuration upstream tests.

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

- The holographic provider takes a `db_path` config key. Pointing several profiles at
  one SQLite file is the low-cost approximation of a shared fact store. With one unix
  user per profile (§5) this needs a shared group (`users.groups.hermes`) and a
  group-writable directory outside every home — the permissions that make the isolation
  real also make the sharing explicit work. Treat it as experimental: upstream's warning
  is about two agents sharing a *home*, not a *DB*, and SQLite/WAL tolerates multiple
  processes, but nothing upstream promises this. Cron runs (§8) mean "they never run
  concurrently" is not a safe assumption.
- Raise `memory.memory_char_limit` / `user_char_limit` further (the current host is
  already at 4× the module defaults, 8800/5500). This addresses "the memory is small"
  only in how much is injected into the prompt — it is not retrieval.

**Later: self-hosted Honcho.** The per-user split makes this *more* attractive, not
less: Honcho is reached over HTTP with a workspace and a peer name, so it is indifferent
to which uid is calling. It is the only provider with native cross-profile sharing — it
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
| `hermes-forgejo-ssh.age` | **keep, re-minted** — the new `hermes` Forgejo account's own key, owned by the `coding` user (§5.1) |
| `hermes-forgejo-token.age` | **new**, optional — REST-API token for `fj`, only if `forgejo-cli.nix` is imported |
| `axon-gateway-env.age` | keep **and add `hostHermes`** — line 42 lists `hostMcp hostDevelopment hostOtel hostZeroclaw` only; the harness needs it too |
| `moshi-device-id.age` | **add `hostHermes`** — line 69 omits it (§7.5) |
| `ventara-gateway-env.age` | add if `ventara-gateway` MCP is wanted; `coding-harness.nix` registers it |
| `hermes-api-server-key.age` | delete — no api_server |

Both "add `hostHermes`" items are pre-existing breakage, not work created by this
rebuild: the config declares those secrets today and they cannot decrypt on that host.

**Per-profile keys.** Each profile reads only its own `.env`, so giving profiles
different providers means one agenix file per profile — `hermes-coding-env.age`,
`hermes-research-env.age`, `hermes-kb-env.age` — each holding that profile's
`DEEPSEEK_API_KEY` / `OPENCODE_ZEN_API_KEY`, with `owner` set to that profile's unix
user. The rendering in §7.3 concatenates them into `/home/<name>/.hermes/.env`. With
separate uids, "profile A cannot read profile B's key" is enforced by mode 0400 rather
than by Hermes.

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
  **add `hermes-dashboard.homelab.internal`** at the same address (§9.1).
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
   - `claude login` as the `coding` user (§6.2), if Claude Code is to be used.
   - Forgejo web UI: create the `hermes` account, register the new public key on it,
     grant collaborator access, and add it to the push whitelist on each protected
     `main` (§5.2, §5.2.1). Verify with a throwaway commit pushed from the host before
     trusting the `coding` profile with real work.
8. Verify, in this order:
   - `systemctl status hermes-config-check` → active/exited, no "repaired" surprises.
   - `journalctl -u hermes-agent -b | grep -c 'Falling back to default config'` → 0.
   - As each profile user: `hermes gateway status` → its own gateway, and the three
     coexist (the §5.3 host-lock question — check this early, it is load-bearing).
   - `sudo -u research hermes` and `sudo -u kb hermes` → each sees only its own home,
     model and memory.
   - `hermes plugins compat ~/.hermes/plugins/moshi-hooks` per profile user → exit 0
     (findings §3.1).
   - `curl -I https://hermes-dashboard.homelab.internal` → 200 **and a login
     challenge**. If it loads the UI with no auth, stop and fix §9.1(1) before
     anything else.
   - `moshi-hook status --json | jq .paired` → `true`, and a test notification lands on
     the phone (§7.5).
   - `sudo -u coding -i`, then `opencode run "print the repo name"` in a `~/code`
     checkout → completes, and `claude -p` likewise if logged in.
   - As `coding`: make a scratch edit, then `/rollback` in a session restores it (§7.5).
   - A throwaway one-minute cron job on one profile → runs, and the result reaches the
     phone by whichever path §8.1 established.
   - `mosh coding@homelab-hermes` from the phone → `hermes` starts on that profile.
9. Only then remove the hermes backend from Open WebUI (§12) — the last thing still
   pointed at the old interface.

## 14. Open Questions

- **Do moshi hooks fire on unattended cron runs?** (§8.1) Decides whether cron needs a
  `deliver` target at all.
- **Claude Code credentials for unattended use** (§6.2). opencode has an agenix key;
  Claude Code appears to need an interactive login, which does not suit cron.
- **Does the host-wide gateway lock permit one gateway per unix user?** (§5.3) The
  load-bearing assumption of the whole per-user design — issue #109954 describes it
  working in production, but verify on `v2026.9.21` before building on it.
- **Per-user homes vs. one unified dashboard** (§9.1). Both were asked for and they
  conflict; (a) three dashboards or (b) one uid with real profiles. Needs a decision
  before §5 is implemented, not after.
- **How the dashboard gets authenticated** (§9.1) — Caddy-side (Pocket ID forward auth)
  or Hermes-side OIDC on a non-loopback bind.
- **System services or the home-manager module?** (§5.2) Turns on whether
  `IPAddressDeny`/`IPAddressAllow` survive in a systemd user unit.
- **Do the harness modules get proper options?** (§6) They read `homelab.agent.*`, which
  no longer describes this host; `enable = false` + a repointed `user` works but is a
  lie in the option name.
- **`hermesHomeFiles` vs `documents`** for SOUL.md on the new version (findings §3.2) —
  affects §7.3's activation script and the `ReadOnlyPaths` list. Check before writing
  the module.
- **Which profiles get which provider/model**, and therefore how many per-profile
  secrets to create (§11). The table in §7.2 is a starting proposal.
- **Is `research`/`kb` worth a gateway each**, or CLI-only (no unit, no cron) until they
  earn one? Three idle gateways is three idle Python processes.
- **Does one Moshi token pair three hosts?** Unverified, and this rebuild makes hermes
  the host where it matters most (§7.5).
