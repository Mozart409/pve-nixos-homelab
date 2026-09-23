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
- Profiles: `default`, `coding`, `research`, `kb` — separate `config.yaml`, `.env`,
  `SOUL.md`, memory, sessions and **cron jobs** per profile (§8).
- A dedicated non-sudo agent account with a Forgejo collaborator SSH key (§5),
  pushing `main` directly, with `repo-sync` keeping its `~/code` checkouts current.
- The shared coding harness: Claude Code + opencode, repo skills and commands, MCP
  wiring (§6).
- moshi-hook (per profile) + mosh/ssh over Tailscale as the *only* human interfaces.

**Out (deleted, not migrated):**

- The api_server, its Caddy vhosts, the step-ca/Tailscale cert wiring, port 443, and
  the `hermes-api-server-key` secret. Open WebUI stops being a client (§12).
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

## 5. The Agent Account

`modules/agent-user.nix` already implements exactly what is wanted here, and
`hosts/development` is the working precedent. Import it and turn it on:

```nix
homelab.agent.enable = true;   # user = "agent", home = /home/agent, no sudo
```

What that gives, for free:

- A normal (non-system) account with **no sudo at all** — an explicit
  `security.sudo.extraRules` deny, not just an absent grant, so a later `extraRules`
  cannot quietly widen it. The OS is the boundary; the harness deny-lists are
  convenience on top (AGENTS.md §8).
- `amadeus`'s SSH keys in its `authorized_keys`, so `ssh agent@homelab-hermes` and
  mosh work straight from the phone (§9), plus `linger = true` so its user services
  start at boot without a login.
- The Forgejo key wired as an ssh `Match user agent host forgejo.*` block — port 2222,
  `User forgejo`, `IdentitiesOnly yes`, `IdentityAgent none` — so every git operation
  by that account uses the collaborator key and nothing else.

### 5.1 One account, not two

The upstream module creates its own `hermes` user (`createUser = true`, `user = "hermes"`,
home = `stateDir`). Two modules defining `users.users.<name>` with different
`isNormalUser` / `home` / `shell` will conflict, and more importantly a *second*
account defeats the point: the Hermes agent's `terminal` tool must run as the same user
whose `$HOME` holds the harness config (`~/.claude`, `~/.config/opencode`) and the repo
checkouts. So run the agent as the agent account:

```nix
services.hermes-agent = {
  user        = config.homelab.agent.user;   # "agent"
  createUser  = false;                       # agent-user.nix owns the account
  stateDir    = config.homelab.agent.home;   # /home/agent → .hermes/ inside it
};
```

Profiles then live at `/home/agent/.hermes/profiles/<name>/`, and the same `$HOME` is
what an interactive mosh session sees. The module's `commonServiceConfig` sets
`ProtectHome = false`, so `/home/agent` is reachable from inside the unit;
`ReadWritePaths` is `[stateDir, workingDirectory]`, which now covers the home.

**Verify during the bump** that `user`, `createUser` and a non-`/var/lib` `stateDir`
behave as documented on `v2026.9.21` — the option list was read from
`nix/nixosModules.nix` on main, not exercised.

### 5.2 The Forgejo key

`modules/agent-user.nix` hardcodes `age.secrets.agent-forgejo-ssh` pointing at
`secrets/agent-forgejo-ssh.age`. Two ways to give hermes a key:

1. **Add `hostHermes` to `agent-forgejo-ssh.age`.** One line, but both hosts then push
   as the same Forgejo identity — attribution and revocation stop being per-host.
2. **Give the module an option** (`homelab.agent.forgejoKeyFile`, defaulting to the
   current path) and point hermes at its own secret. `hermes-forgejo-ssh.age` already
   exists — it is the `hermes-bot` account's key, and `hermes-bot` is already a Write
   collaborator on `amadeus/pve-nixos-homelab` (AGENTS.md §7). Reuse it.

**Recommend (2).** It is a ~6-line module change, keeps `hermes-bot` as a distinct
Forgejo identity that can be revoked alone, and reuses a secret and a collaborator
grant that already exist. Note this reverses the earlier plan's "delete
`hermes-forgejo-ssh`" — that secret stays.

### 5.2.1 It pushes `main` — decided

Same model as `development`: the agent commits and pushes `main` directly, with no PR
round-trip. That removes the feature-branch protocol from the `coding` profile's
SOUL.md entirely — it commits and pushes like a person would.

**This needs a Forgejo-side change, and it is not the same change `development`
needed.** `development`'s agent was never blocked because `agent-forgejo-ssh` holds
*amadeus's own collaborator key* — that host pushes as you (`modules/agent-user.nix`:
"The agent still commits and pushes with your Forgejo identity — that is deliberate").
`hermes-bot` is a separate account, and `main` on `amadeus/pve-nixos-homelab` is
protected with no push whitelist precisely so that account could not land changes
(AGENTS.md §7). So: **add `hermes-bot` to the push whitelist on the protected `main`
branch**, per repo it should work in. Web UI, one setting; nothing in this repo.

Two consequences worth stating before doing it:

- **Nothing auto-deploys from `main` any more.** Comin was removed on 2026-09-08
  (`todo/comin-removal-cleanup.md`), so a push to `main` reaches Forgejo and stops
  there — `repo-sync` fast-forwards the human clone, and a person still runs
  `just self-deploy` / `colmena`. Had comin still been running, an agent push to `main`
  would have been a fleet-wide unreviewed deploy; it is not.
- **AGENTS.md §7 becomes wrong.** That section documents the feature-branch workflow,
  the `~/workspace/pve-nixos-homelab` checkout, the `homelab-config-repo` skill and
  "main is branch-protected, so the bot can never land changes directly". All four are
  superseded here; rewriting it is part of the work (§12).

The alternative — pasting amadeus's collaborator key into a hermes-side secret, as
`development` does — would also work and need no Forgejo change, but it gives up
per-host revocation and makes every hermes commit indistinguishable from yours. Not
recommended.

### 5.3 Repo checkouts

```nix
homelab.repoSync.${config.homelab.agent.user} = {
  sshKey = config.age.secrets.hermes-forgejo-ssh.path;   # or agent-forgejo-ssh, per §5.2
  push   = true;
};
```

`modules/repo-sync.nix` then walks every checkout under `~/code` on a timer: fetch →
`merge --ff-only` (refuses on divergence) → plain `push` (no `--force`, ever). It never
commits or rebases, and exits 0 on every skippable state, so a dirty tree is not a
failure. That is how agent commits reach Forgejo without a human step, and it answers
the old plan's open question about what the `coding` profile operates on: clones under
`/home/agent/code`.

## 6. Coding Harness — opencode and Claude Code

The agent should not be doing code edits with Hermes' own `file`/`patch` tools when a
purpose-built harness already exists in this repo. Import the same set `development`
does:

```nix
imports = [
  ../../modules/agent-user.nix
  ../../modules/coding-harness.nix
  ../../modules/claude-permissions.nix
  ../../modules/claude-settings-verify.nix
  ../../modules/repo-sync.nix
  ../../modules/moshi-hook-user.nix
  ../../modules/forgejo-cli.nix      # optional: `fj` for repo creation over REST
  # ../../modules/herdr.nix          # optional: terminal workspace for mosh sessions
];
```

`modules/coding-harness.nix` reads `config.homelab.agent.{user,home}` and renders, for
that account: Claude Code's `~/.claude/settings.json` (MCP servers as `type = "http"`
with `${VAR}` header expansion), opencode's `~/.config/opencode/` (same servers as
`type = "remote"` with `{env:VAR}` expansion), the repo's skills from
`.opencode/skills/` symlinked into `~/.claude/skills/` (read by *both* tools), and the
slash-commands from `.opencode/command/`. MCP servers come from one list in that
module — `axon-gateway` and `ventara-gateway` — so hermes inherits both by importing it.

### 6.1 What Hermes actually runs

Hermes' `terminal` toolset (backend `local`) executes as the agent account, so the
harness is simply on its PATH. The `coding` profile's SOUL.md directs it to shell out
rather than edit directly, e.g. `opencode run "<task>"` inside
`/home/agent/code/<repo>`, or `claude -p "<prompt>"`. Consequences worth writing into
the config comments:

- **Guardrails come from the harness, not from Hermes.** Hermes' approval layer sees
  one `opencode` invocation; everything the nested agent then does is governed by
  `modules/claude-permissions-data.nix` and the `opencodePermissions` block — plus the
  non-sudo account, which is the only real boundary.
- **Resource caps must be raised.** The current unit sets `MemoryHigh = 3G`,
  `TasksMax = 512`, `LimitNPROC = 512`. A nested node/opencode process plus a
  `nix develop` will exceed that. Raise or drop `MemoryHigh` (the existing comment
  already explains why there is deliberately no `MemoryMax`), and lift the task caps.
- **`IPAddressAllow` must cover Forgejo** (192.168.2.178 — already listed) for git, and
  the internet stays open for `api.anthropic.com` / opencode-zen since the deny list
  only covers RFC1918 + CGNAT.
- **Cost compounds.** Each nested run bills its own provider. A cron job that calls
  `opencode` is two agents' worth of tokens per tick.

### 6.2 Packaging and credentials

- **`claude-code` is unfree.** The `hermes` entry in `nixosConfigurations` already sets
  `nixpkgs.config.allowUnfree = true` (it was added for nixvim), so nothing new is
  needed there — but unfree packages are not on `cache.nixos.org`, so it builds locally
  on the deploy host the first time.
- **`crush`** comes from the `nix-ai-tools` flake input, which the `hermes`
  `nixosSystem` entry does **not** pass in `specialArgs` (only `development` does).
  Either add `specialArgs = { inherit nix-ai-tools; }` there, or skip crush.
- **opencode's key**: `modules/coding-harness.nix` expects the generic attribute
  `age.secrets.opencode-zen-key`. Declare it on hermes pointing at the existing file,
  mirroring how `development` maps its own:

  ```nix
  age.secrets.opencode-zen-key = {
    file  = ../../secrets/hermes-opencode-zen-key.age;
    owner = config.homelab.agent.user;
    mode  = "0400";
  };
  ```
- **Claude Code's credentials are the open problem.** There is no Anthropic key secret
  in this repo — `development` implies a one-time interactive `claude login` as the
  agent account, with the result living in `~/.claude`. On a freshly wiped host that is
  a manual post-install step, and an OAuth session is a poor fit for *unattended* cron
  runs. Treat **opencode as the unattended path** (its key is an agenix file) and
  Claude Code as the interactive one, until there is a key-based answer.

## 7. Profiles

### 7.1 What upstream gives us

A profile is a complete second Hermes home at `$HERMES_HOME/profiles/<name>/` with its
own `config.yaml`, `.env`, `SOUL.md`, `memories/`, `sessions/`, `skills/`, cron jobs
and `state.db`. A named profile resolves providers **only** from its own `auth.json`
and `.env` — it never inherits the root profile's keys. So "different API keys per
profile" is native, not something we have to build.

Access: `hermes -p coding chat`, or the auto-generated `~/.local/bin/coding` wrapper
(which just sets `HERMES_HOME=…/profiles/coding`), or a sticky `hermes profile use`.

Hard rule from upstream, worth repeating in our config comments: **never point two
agent processes at the same profile home.** Both write memory, and each loads the
other's writes into its system prompt at session start.

### 7.2 Proposed profiles

| Profile | Purpose | Model | Toolsets | Harness |
| --- | --- | --- | --- | --- |
| `default` | host multiplexer, cron owner, catch-all | `deepseek-v4-flash` | file, memory, skills, web, session_search, cronjob | — |
| `coding` | drives opencode/claude in `~/code` | `deepseek-v4-pro` | + terminal, code_execution, delegation | yes |
| `research` | reading, synthesis | `deepseek-v4-pro` | + web (search **and** extract, findings §4.1) | — |
| `kb` | notes / knowledge capture | `deepseek-v4-flash` | file, memory, skills, session_search | — |

Keep each toolset list minimal: every enabled toolset costs tool-schema tokens on every
LLM call, and `browser` in particular should stay off until it has an engine (findings
§4.2).

The `coding` profile's SOUL.md is correspondingly short on git ceremony (§5.2.1): work
in a `~/code` checkout, commit through the dev shell so the lefthook `alejandra` /
`keep-sorted` hooks run, push `main`. What it still must carry is the validation rule —
a scoped `nix eval '.#nixosConfigurations.<host>.…drvPath'` per edited host, never the
full `nix flake check`, which evaluates ~16 hosts and gets OOM-killed.

### 7.3 Making profiles declarative

The NixOS module is single-home: `stateDir`, `settings`, `documents`, `environment`,
`environmentFiles` all describe exactly one Hermes home. There is **no profile option**
upstream. So the profiles need a small local module, e.g. `modules/hermes-profiles.nix`:

- Input: an attrset `profiles.<name> = { settings, soul, environmentFiles, … }`.
- For each profile, render `config.yaml` (via `pkgs.writeText` + the same YAML shape
  the module uses) and `SOUL.md` into the Nix store.
- A root activation script installs them to
  `/home/agent/.hermes/profiles/<name>/`, `chown` to the agent account, and
  concatenates the profile's agenix secret files into that profile's `.env`
  (mode 0600) — the same pattern the upstream module already uses for the root home.
- Bind each rendered `config.yaml` and `SOUL.md` read-only in the unit's
  `ReadOnlyPaths`, as the current config does for the root profile, so the agent cannot
  rewrite its own prompt or model at runtime.

Two things to preserve from the current host while doing this:

- **The config.yaml integrity gate.** `hermes-config-check` exists because a malformed
  `config.yaml` makes Hermes fail *open* to built-in defaults (AGENTS.md §6). With N
  profiles there are N files that can be corrupted, so the check must loop over
  `profiles/*/config.yaml`, not just the root one.
- **`secretNonce`.** Nothing about writing files at stable paths changes the unit
  definition, so a deploy does not restart the agent. Keep the nonce and bump it when
  any profile's config, SOUL or secret changes.

### 7.4 Gateways: exactly one, multiplexing

As of `v2026.9.21` there is a **host-wide singleton lock**: one `hermes gateway run`
per machine, full stop. A second gateway starts in observe-only mode. The mechanism is
a per-role flock plus a published rendezvous record (pid, port, protocol version, token
fingerprint, served-profile set).

So do **not** create one systemd unit per profile. Instead:

```yaml
# profiles/default/config.yaml (the root profile only)
gateway:
  multiplex_profiles: true
```

The default profile's gateway becomes the host multiplexer and serves every enabled
profile; profiles created later are picked up live without a restart. Per-profile
lifecycle is then `hermes -p coding gateway stop|start` (parking/unparking via a
`gateway.parked` marker), not a second process.

**Footgun to check:** the upstream module's `ExecStart` is
`hermes gateway run --replace`, and issue #119837 reports that `--replace` skips the
host-lock refusal — a supervised unit that loses a start race can end up running a
second gateway beside the multiplexer. With a single unit this is unlikely, but verify
`hermes gateway status` reports one owner after boot.

### 7.5 moshi-hook per profile

`moshi-hook install` writes into `$HERMES_HOME/.hermes/config.yaml` — i.e. into
*whichever* home `HERMES_HOME` points at. With four profiles that is four installs, and
four copies of the mixed-indent corruption footgun that `hermes-config-check` exists to
repair (AGENTS.md §6; `hosts/hermes/moshi-hook.nix`).

Keep the existing discipline and extend it:

- `plugins.enabled = ["moshi-hooks"]` stays **declarative per profile** in Nix.
- `moshi-hook install` runs once per `(profile, moshi-hook version)` pair, guarded by a
  per-profile stamp file, with `HERMES_HOME` set to that profile's directory.
- `hermes-config-check` repairs every profile's file afterwards (§7.3).
- Pairing (`moshi-hook pair --token`) is per host, not per profile, and stays a single
  oneshot. `modules/moshi-hook-user.nix` additionally runs the hook daemon in the agent
  account's user manager, which is what makes interactive sessions notify.

**Blocker — the moshi token is not encrypted to this host.**
`secrets/secrets.nix:69` lists `moshi-device-id.age` recipients as
`[… hostDevelopment hostZeroclaw]` — **`hostHermes` is absent**, while
`hosts/hermes/configuration.nix:393` declares `age.secrets.moshi-device-id`. agenix
fails that secret softly (AGENTS.md: a decrypt failure records status and never aborts
the loop), and the pair script's own fallback is `"moshi-device-id secret unreadable,
skipping"` — which exits 0. The net effect is a host that never pairs, silently. Since
moshi-hook is now the primary interface, fix this first (§11).

Also unresolved and noted in the current config: it is **unverified whether one Moshi
account token can pair three hosts** (development, zeroclaw, hermes) simultaneously, or
whether pairing a new host invalidates the previous one. Verify on the rebuilt host
before assuming push works.

## 8. Cron

Cron is the reason the gateway stays. Its shape on a multi-profile host:

- **Storage is per profile**: jobs live in `<profile>/cron/jobs.json`. A job created in
  a `hermes -p research chat` session belongs to `research`, runs with `research`'s
  model, keys, SOUL and memory, and nothing else sees it.
- **Execution is one ticker**: the gateway's 60 s tick drives every job, and with
  `multiplex_profiles: true` (§7.4) that single process ticks all four profiles. No
  extra unit, no per-profile timer.
- **Runs are unattended and fresh**: each job gets a new session with no human present.
  Keep `platform_toolsets.cron` lean — upstream warns that heavy toolsets
  (browser/delegation) bloat the tool-schema prompt on *every LLM call of every job* —
  and note that `cronjob` is force-disabled inside cron runs (anti-recursion guard),
  while per-job `enabled_toolsets` on `cronjob.create` still overrides the default.
- **`approvals.cron_mode`** decides what happens when a cron run trips a dangerous
  command. Set it explicitly per profile (`deny` unless a specific profile needs
  otherwise) rather than inheriting; see findings §4.3 for how it relates to
  `approvals.mode = "smart"` and `unattended_mode`.
- **Stateful jobs** (0.21.0): jobs carry persistent memory between runs and can skip
  the LLM call entirely when nothing changed. Worth using for anything polling.

### 8.1 Delivery

Upstream now delivers the agent's final response itself — "the agent does not send
messages itself, so there is nothing to call in the cron prompt". Each job stores a
`deliver` target; supported values include `homeassistant`, `webhook`, `origin`,
`local`, and `platform:chat_id` forms. Delivery is tracked **separately from
execution**: a run whose output never landed records `last_status: delivery_failed`
with `last_delivery_error`, instead of a green `ok`.

For a moshi-first host there are two candidate paths, and they are not equivalent:

1. **The moshi-hooks plugin fires on the run's own events.** If the hooks installed
   into each profile (§7.5) also fire for unattended cron sessions, the phone gets a
   push with no `deliver` target at all. This is the outcome to want — **verify it
   before building anything else**, with a one-minute throwaway job.
2. **`deliver: homeassistant`** (or a `webhook` at HA/ntfy), which is what today's
   hand-written `cron-result-delivery` skill does by hand via `hamcp_call_service`.
   Use this if (1) turns out not to cover cron runs.

Either way the hand-rolled skill goes: it exists only because the old version had no
delivery path, and it cannot report a failed delivery.

## 9. Access Path

No Caddy, no 443, no api_server. The host is reached as:

1. **mosh/ssh over Tailscale.** `modules/common.nix` already enables `programs.mosh`
   and opens udp 60000–61000, and `trustedInterfaces = ["tailscale0"]` covers the
   tailnet side. Firewall shrinks to `allowedTCPPorts = [22 9100]` (ssh + node
   exporter); drop 443.
2. **Log in as the agent account.** `modules/agent-user.nix` puts `amadeus`'s SSH keys
   in its `authorized_keys`, so the phone session is `mosh agent@homelab-hermes` →
   `coding chat`, with no sudo hop and no wrapper script. `sudo -u agent -i` from
   `amadeus` works too when you are at a real terminal.
3. **moshi-hook** for push out of agent sessions (§7.5) and, ideally, out of cron runs
   (§8.1).

Keep the agent off the `amadeus` account: `amadeus` is in wheel with passwordless sudo
on every host, and an agent that runs a shell — and now shells out to *other* agents —
must not sit inside it. That is the same reasoning that produced the split on
`development` on 2026-09-14.

Optionally import `modules/herdr.nix` so a reconnecting mosh session lands back in a
persistent workspace instead of a bare shell.

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
  one SQLite file is the low-cost approximation of a shared fact store. Treat it as
  experimental: upstream's warning is about two agents sharing a *home*, not a *DB*,
  and SQLite/WAL tolerates multiple processes — but nothing upstream promises this.
  If it is tried, only give it to profiles that will not run concurrently — which now
  includes cron runs (§8), so check the schedule before assuming that holds.
- Raise `memory.memory_char_limit` / `user_char_limit` further (the current host is
  already at 4× the module defaults, 8800/5500). This addresses "the memory is small"
  only in how much is injected into the prompt — it is not retrieval.

**Later: self-hosted Honcho.** The only provider with native cross-profile sharing — it
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
| `hermes-forgejo-ssh.age` | **keep** — repurposed as the agent account's collaborator key (§5.2) |
| `axon-gateway-env.age` | keep **and add `hostHermes`** — line 42 lists `hostMcp hostDevelopment hostOtel hostZeroclaw` only; the harness needs it too |
| `moshi-device-id.age` | **add `hostHermes`** — line 69 omits it (§7.5) |
| `ventara-gateway-env.age` | add if `ventara-gateway` MCP is wanted; `coding-harness.nix` registers it |
| `hermes-api-server-key.age` | delete — no api_server |

Both "add `hostHermes`" items are pre-existing breakage, not work created by this
rebuild: the config declares those secrets today and they cannot decrypt on that host.

**Per-profile keys.** Since a named profile reads only its own `.env`, giving profiles
different providers means one agenix file per profile, e.g.
`hermes-profile-coding-env.age`, each holding that profile's `DEEPSEEK_API_KEY` /
`OPENCODE_ZEN_API_KEY`. The profile module (§7.3) concatenates them into
`profiles/<name>/.env`.

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
  records at 192.168.2.155 (still wanted for ssh/mosh) and the hosts-file entry.
- **`hosts/otel/*`** — the hermes blackbox probes were already removed on 2026-09-10;
  the `hermes-node` scrape job can come back once the host is up, since node exporter
  on 9100 stays.
- **`flake.nix`** — uncomment the `hermes` entry in `colmenaHive` (disabled 2026-09-09
  for "No route to host"). Until then only `nix eval` / `just deploy` reach this host,
  and `just cah hermes` does not work.
- **Forgejo** — confirm `hermes-bot`'s collaborator grants cover every repo the
  `coding` profile should touch, and add it to the push whitelist on each protected
  `main` (§5.2.1).
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
   - `claude login` as the agent account (§6.2), if Claude Code is to be used.
   - Forgejo web UI: confirm `hermes-bot`'s collaborator grants, and add it to the
     push whitelist on each protected `main` (§5.2.1). Verify with a throwaway commit
     pushed from the host before trusting the `coding` profile with real work.
8. Verify, in this order:
   - `systemctl status hermes-config-check` → active/exited, no "repaired" surprises.
   - `journalctl -u hermes-agent -b | grep -c 'Falling back to default config'` → 0.
   - `hermes gateway status` → exactly one owner (§7.4).
   - `hermes profile list` → all four, each with its own model.
   - `hermes plugins compat …/profiles/<n>/plugins/moshi-hooks` → exit 0 per profile
     (findings §3.1).
   - `moshi-hook status --json | jq .paired` → `true`, and a test notification lands on
     the phone (§7.5).
   - `sudo -u agent -i`, then `opencode run "print the repo name"` in a `~/code`
     checkout → completes, and `claude -p` likewise if logged in.
   - A throwaway one-minute cron job on one profile → runs, and the result reaches the
     phone by whichever path §8.1 established.
   - `mosh agent@homelab-hermes` from the phone → `coding chat` starts.
9. Only then remove the hermes backend from Open WebUI (§12) — the last thing still
   pointed at the old interface.

## 14. Open Questions

- **Do moshi hooks fire on unattended cron runs?** (§8.1) Decides whether cron needs a
  `deliver` target at all.
- **Claude Code credentials for unattended use** (§6.2). opencode has an agenix key;
  Claude Code appears to need an interactive login, which does not suit cron.
- **Does `user` + `createUser = false` + a `/home` `stateDir` work on `v2026.9.21`?**
  (§5.1) Read from the module source, not exercised.
- **`hermesHomeFiles` vs `documents`** for SOUL.md on the new version (findings §3.2) —
  affects §7.3's activation script and the `ReadOnlyPaths` list. Check before writing
  the module.
- **Which profiles get which provider/model**, and therefore how many per-profile
  secrets to create (§11). The table in §7.2 is a starting proposal.
- **Does one Moshi token pair three hosts?** Unverified, and this rebuild makes hermes
  the host where it matters most (§7.5).
